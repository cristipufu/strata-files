import Foundation
import Synchronization
import Testing
@testable import StrataFiles

struct S3UploadResponseTests {
    @Test(arguments: [0, 8])
    func repliesAtTheByteLimitRemainReadable(_ count: Int) async throws {
        let body = Data(repeating: 7, count: count)
        let fixture = UploadReplyFixture(chunks: [body])
        let (reply, response) = try await S3Upload.response(to: fixture.task, maximumBytes: 8, progress: { _ in })
        #expect(reply == body)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test(arguments: [nil, "8"] as [String?])
    func actualBytesAreBoundedWhenTheLengthIsMissingOrMisleading(_ length: String?) async {
        let fixture = UploadReplyFixture(headers: length.map { ["Content-Length": $0] } ?? [:],
            chunks: [Data(repeating: 7, count: 8), Data([9])])
        await #expect(throws: S3Error.badResponse) {
            try await S3Upload.response(to: fixture.task, maximumBytes: 8, progress: { _ in })
        }
    }

    @Test func cancellationStopsOnlyItsRequestAndReleasesItsDelegate() async throws {
        let held = UploadReplyFixture(finishes: false)
        let other = UploadReplyFixture(chunks: [Data([1, 2])], finishes: false, session: held.session)
        let completed = Mutex(false)
        let operation = Task {
            defer { completed.withLock { $0 = true } }
            return try await S3Upload.response(to: held.task, maximumBytes: 8, progress: { _ in })
        }
        var started = held.plan.started.stream.makeAsyncIterator()
        #expect(await started.next() != nil)
        let otherOperation = Task {
            try await S3Upload.response(to: other.task, maximumBytes: 8, progress: { _ in })
        }
        var otherStarted = other.plan.started.stream.makeAsyncIterator()
        #expect(await otherStarted.next() != nil)
        weak var delegate = held.task.delegate as AnyObject?
        #expect(delegate != nil)
        operation.cancel()
        let deadline = ContinuousClock.now + .seconds(10)
        while !completed.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed.withLock { $0 })
        // End the controlled server response if cancellation regresses, so the test reports a failure and finishes.
        if !completed.withLock({ $0 }) { held.plan.finish() }
        await #expect(throws: CancellationError.self) { try await operation.value }
        while delegate != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(delegate == nil)

        other.plan.finish()
        let (reply, _) = try await otherOperation.value
        #expect(reply == Data([1, 2]))
    }

    @Test func aRequestCancelledBeforeStartingNeverResumesTheUpload() async {
        let fixture = UploadReplyFixture(finishes: false)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await S3Upload.response(to: fixture.task, maximumBytes: 8, progress: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(fixture.task.state == .canceling || fixture.task.state == .completed)
    }

    @Test func progressBelongsToItsActiveUpload() async throws {
        let fixture = UploadReplyFixture(finishes: false)
        let totals = Mutex<[Int64]>([])
        let operation = Task {
            try await S3Upload.response(to: fixture.task, maximumBytes: 8, progress: { total in totals.withLock { $0.append(total) } })
        }
        var started = fixture.plan.started.stream.makeAsyncIterator()
        #expect(await started.next() != nil)
        let delegate = try #require(fixture.task.delegate)
        delegate.urlSession?(fixture.session, task: fixture.task, didSendBodyData: 2, totalBytesSent: 2, totalBytesExpectedToSend: 4)
        #expect(totals.withLock { $0 } == [2])
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        delegate.urlSession?(fixture.session, task: fixture.task, didSendBodyData: 2, totalBytesSent: 4, totalBytesExpectedToSend: 4)
        #expect(totals.withLock { $0 } == [2])
    }
}

private nonisolated final class UploadReplyPlan: Sendable {
    let headers: [String: String]
    let chunks: [Data]
    let finishes: Bool
    let started = AsyncStream<Void>.makeStream()
    private let completion = Mutex<(@Sendable () -> Void)?>(nil)

    init(headers: [String: String], chunks: [Data], finishes: Bool) {
        self.headers = headers; self.chunks = chunks; self.finishes = finishes
    }

    func finish() {
        let action = completion.withLock { action in
            let current = action; action = nil
            return current
        }
        action?()
    }

    func onFinish(_ action: @escaping @Sendable () -> Void) { completion.withLock { $0 = action } }
    func stop() { completion.withLock { $0 = nil } }
}

private nonisolated final class UploadReplyFixture {
    let plan: UploadReplyPlan
    let session: URLSession
    let task: URLSessionUploadTask
    private let url: URL
    private let ownsSession: Bool

    init(headers: [String: String] = [:], chunks: [Data] = [], finishes: Bool = true, session supplied: URLSession? = nil) {
        let url = URL(string: "https://upload.strata.invalid/\(UUID().uuidString)")!
        let plan = UploadReplyPlan(headers: headers, chunks: chunks, finishes: finishes)
        self.url = url; self.plan = plan
        UploadReplyProtocol.plans.withLock { $0[url] = plan }
        ownsSession = supplied == nil
        if let supplied { session = supplied }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UploadReplyProtocol.self]
            session = URLSession(configuration: configuration)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        task = session.uploadTask(with: request, from: Data([1]))
    }

    deinit {
        task.cancel()
        if ownsSession { session.invalidateAndCancel() }
        _ = UploadReplyProtocol.plans.withLock { $0.removeValue(forKey: url) }
    }
}

private nonisolated final class UploadReplyProtocol: URLProtocol, @unchecked Sendable {
    static let plans = Mutex<[URL: UploadReplyPlan]>([:])
    private let active = Mutex<UploadReplyPlan?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "upload.strata.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let plan = Self.plans.withLock({ $0[url] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: plan.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        active.withLock { $0 = plan }
        plan.onFinish { [weak self] in
            guard let self else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if plan.finishes { plan.finish() }
        plan.started.continuation.yield(())
        plan.started.continuation.finish()
    }

    override func stopLoading() { active.withLock { $0 }?.stop() }
}

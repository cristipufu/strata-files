import AppKit
import WebKit
import CPreviewWeb
import CPreviewWebTestSupport
import Testing
@testable import Strata
@testable import StrataPreviews

struct WebResourceTaskTests {
    @Test func nativeExceptionsRetireTheResourceBeforeTheyCanUnwindSwift() throws {
        let url = URL(string: "strata-html://fixture/document.pdf")!
        let response = URLResponse(url: url, mimeType: "application/pdf", expectedContentLength: 1, textEncodingName: nil)
        for point: STWebFailurePoint in [.response, .data, .completion, .failure] {
            let native = STFailingWebSchemeTask()
            native.failurePoint = point
            let guarded = STWebResourceTask(task: native)
            switch point {
            case .response: #expect(!guarded.receive(response))
            case .data:
                #expect(guarded.receive(response))
                #expect(!guarded.receive(Data([1])))
            case .completion:
                #expect(guarded.receive(response) && guarded.receive(Data([1])))
                #expect(!guarded.finish())
            case .failure: guarded.fail(URLError(.cancelled) as NSError)
            default: Issue.record("Unhandled fixture")
            }
            let failure = try #require(guarded.failure) as NSError
            #expect(failure.userInfo["exceptionName"] as? String == "StrataFixtureWebFailure")
            let events = native.events
            #expect(!guarded.receive(response) && !guarded.receive(Data([2])) && !guarded.finish())
            guarded.fail(URLError(.cancelled) as NSError)
            guarded.stop()
            #expect(native.events == events)
        }
    }

    private final class SchemeTask: NSObject, WKURLSchemeTask {
        let request = URLRequest(url: URL(string: "strata-html://fixture/document.pdf")!)
        var events: [String] = []
        var data: [Data] = []
        var onResponse: (() -> Void)?
        var onData: (() -> Void)?
        func didReceive(_ response: URLResponse) { events.append("response"); onResponse?() }
        func didReceive(_ data: Data) { events.append("data"); self.data.append(data); onData?() }
        func didFinish() { events.append("finish") }
        func didFailWithError(_ error: Error) { events.append("failure") }
    }

    @Test func streamedResourcesEnforceLengthsAndStopAtReentrantCancellation() async throws {
        let web = WKWebView(frame: .zero)
        for count in [1, 2, 3] {
            let task = SchemeTask()
            let session = HTMLWebSession(url: task.request.url!, stream: { _ in
                WebPreviewStream(mime: "application/pdf", byteCount: count) { yield in
                    guard await yield(Data([1])), await yield(Data([2])) else { return }
                }
            }, limits: .init(requests: 1, bytes: 3), openLink: { _ in })
            session.webView(web, start: task)
            await session.pendingTasks.first?.value
            #expect(task.events.last == (count == 2 ? "finish" : "failure"))
            #expect(task.data.reduce(0) { $0 + $1.count } <= count)
            session.close()
        }
        for afterResponse in [true, false] {
            let task = SchemeTask()
            let session = HTMLWebSession(url: task.request.url!, stream: { _ in
                WebPreviewStream(mime: "application/pdf", byteCount: 2) { yield in
                    guard await yield(Data([1])), await yield(Data([2])) else { return }
                }
            }, limits: .init(requests: 1, bytes: 2), openLink: { _ in })
            if afterResponse { task.onResponse = { session.webView(web, stop: task) } }
            else { task.onData = { session.close() } }
            session.webView(web, start: task)
            await session.pendingTasks.first?.value
            #expect(task.events == (afterResponse ? ["response"] : ["response", "data"]))
            #expect(session.pendingTasks.isEmpty)
            session.close()
        }
    }

    @Test func cancellingHeldStreamsReleasesTheNativeTaskAndDropsLateData() async throws {
        let gate = PreviewReadGate<Data>()
        let web = WKWebView(frame: .zero)
        var native: SchemeTask? = SchemeTask()
        weak var released = native
        let url = try #require(native?.request.url)
        let session = HTMLWebSession(url: url, stream: { _ in
            WebPreviewStream(mime: "application/pdf", byteCount: 1) { yield in
                let data = try await gate.read()
                _ = await yield(data)
            }
        }, limits: .init(requests: 1, bytes: 1), openLink: { _ in })
        session.webView(web, start: try #require(native))
        await gate.waitUntilStarted()
        let work = try #require(session.pendingTasks.first)
        session.close()
        await gate.waitUntilCancelled()
        #expect(native?.events == ["response"])
        native = nil
        #expect(released == nil)
        gate.finish(.success(Data([1])))
        await work.value
        #expect(session.pendingTasks.isEmpty)
    }

    @Test func cancellationDuringANativeExceptionDoesNotPublishALateFailure() async throws {
        let native = STFailingWebSchemeTask()
        native.failurePoint = .response
        let web = WKWebView(frame: .zero)
        let session = HTMLWebSession(url: native.request.url!, read: { _ in
            HTMLPreviewResource(data: Data([1]), mime: "application/pdf")
        }, openLink: { _ in })
        var failures = 0
        session.onFailure = { failures += 1 }
        native.eventOccurred = { [weak session, weak native] in
            guard let session, let native else { return }
            session.webView(web, stop: native)
        }
        defer { native.eventOccurred = nil; session.close() }
        session.webView(web, start: native)
        await session.pendingTasks.first?.value
        #expect(native.events == ["response"] && failures == 0 && session.pendingTasks.isEmpty)
    }

    @Test func rejectedRequestsRetireTheRendererWhenTheirNativeFailureCallbackThrows() {
        let native = STFailingWebSchemeTask()
        native.failurePoint = .failure
        let session = HTMLWebSession(url: native.request.url!, read: { _ in
            Issue.record("A refused request must not read content")
            throw URLError(.cancelled)
        }, limits: .init(requests: 0), openLink: { _ in })
        let web = WKWebView(frame: .zero)
        var failures = 0
        session.onFailure = { failures += 1 }
        session.webView(web, start: native)
        #expect(failures == 1 && native.events == ["failure"] && session.pendingTasks.isEmpty)
        session.close()
        let late = STFailingWebSchemeTask()
        late.failurePoint = .failure
        session.webView(web, start: late)
        #expect(failures == 1 && late.events == ["failure"] && session.pendingTasks.isEmpty)
    }

    @Test func invalidStreamLengthsAreRejectedBeforeTheProducerRuns() async {
        let web = WKWebView(frame: .zero)
        for count in [Int.min, -1, 4, Int.max] {
            let native = SchemeTask()
            let session = HTMLWebSession(url: native.request.url!, stream: { _ in
                WebPreviewStream(mime: "application/pdf", byteCount: count) { _ in
                    Issue.record("Invalid resource lengths must be rejected before streaming")
                }
            }, limits: .init(requests: 1, bytes: 3), openLink: { _ in })
            session.webView(web, start: native)
            await session.pendingTasks.first?.value
            #expect(native.events == ["failure"] && session.pendingTasks.isEmpty)
            session.close()
        }
    }
}

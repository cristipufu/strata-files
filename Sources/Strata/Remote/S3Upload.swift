import Foundation
import Synchronization

/// Upload tasks deliver their response incrementally; the async upload convenience API buffers it in full.
nonisolated final class S3Upload: NSObject, URLSessionDataDelegate, Sendable {
    private typealias Reply = (Data, URLResponse)
    private typealias Completion = CheckedContinuation<Reply, any Error>
    private struct State {
        var task: URLSessionUploadTask?
        var completion: Completion?
        var result: Result<Reply, any Error>?
        var response: URLResponse?
        var body = Data()
    }

    private let state: Mutex<State>
    private let maximumBytes: Int
    private let progress: @Sendable (Int64) -> Void

    private init(task: URLSessionUploadTask, maximumBytes: Int, progress: @escaping @Sendable (Int64) -> Void) {
        state = Mutex(State(task: task))
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    /// Owns a suspended upload through its reply, cancelling only that task when its caller leaves.
    static func response(to task: URLSessionUploadTask, maximumBytes: Int,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws -> (Data, URLResponse) {
        guard maximumBytes >= 0 else { task.cancel(); throw S3Error.badResponse }
        let reader = S3Upload(task: task, maximumBytes: maximumBytes, progress: progress)
        task.delegate = reader
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reader.start($0) }
        } onCancel: {
            reader.finish(.failure(CancellationError()), cancel: true)
        }
    }

    private func start(_ completion: Completion) {
        let pending = state.withLock { state -> (Result<Reply, any Error>?, URLSessionUploadTask?) in
            if let result = state.result { return (result, nil) }
            state.completion = completion
            return (nil, state.task)
        }
        if let result = pending.0 { completion.resume(with: result) }
        else if let task = pending.1 { task.resume() }
        else { finish(.failure(S3Error.badResponse)) }
    }

    private func finish(_ result: Result<Reply, any Error>, cancel: Bool = false) {
        let pending = state.withLock { state -> (Completion?, URLSessionUploadTask?)? in
            guard state.result == nil else { return nil }
            state.result = result
            let pending = (state.completion, state.task)
            state.completion = nil
            state.task = nil
            state.response = nil
            state.body = Data()
            return pending
        }
        guard let pending else { return }
        if cancel { pending.1?.cancel() }
        pending.0?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            finish(.failure(S3Error.badResponse), cancel: true)
            completionHandler(.cancel)
            return
        }
        let accepted = state.withLock { state in
            guard state.result == nil else { return false }
            state.response = response
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = state.withLock { state in
            guard state.result == nil else { return false }
            guard data.count <= maximumBytes - state.body.count else { return true }
            state.body.append(data)
            return false
        }
        if oversized { finish(.failure(S3Error.badResponse), cancel: true) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result = state.withLock { state -> Result<Reply, any Error> in
            if let error { return .failure(error) }
            guard let response = state.response else { return .failure(S3Error.badResponse) }
            return .success((state.body, response))
        }
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                            totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if state.withLock({ $0.result == nil }) { progress(totalBytesSent) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

import Foundation

/// NetFS still owns mounting and its login dialogs. Supplying the mount operation lets headless sheets exercise
/// cancellation without contacting a server or presenting authentication UI.
nonisolated package struct ServerMounter: Sendable {
    package typealias Result = Swift.Result<URL, ServerConnection.Problem>?
    package let mount: @Sendable (URL, ServerConnection.Request) async -> Result

    package init(mount: @escaping @Sendable (URL, ServerConnection.Request) async -> Result) {
        self.mount = mount
    }

    package static let live = ServerMounter { await ServerConnection.mount($0, request: $1) }
}

/// A sheet owns one mount at a time. Cancelling or replacing it detaches the old result before asking NetFS to stop;
/// a late success, failure or cancellation cannot update a newer attempt's controls or recent addresses.
@MainActor package final class ServerMountSession {
    private let mounter: ServerMounter
    private var request: ServerConnection.Request?
    package private(set) var task: Task<Void, Never>?
    package var isConnecting: Bool { request != nil }

    package init(mounter: ServerMounter) { self.mounter = mounter }

    isolated deinit { cancel() }

    @discardableResult
    package func connect(_ url: URL, receive: @escaping (ServerMounter.Result) -> Void) -> Task<Void, Never> {
        cancel()
        let request = ServerConnection.Request(), mounter = mounter
        self.request = request
        let work = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await mounter.mount(url, request)
            } onCancel: {
                request.cancel()
            }
            guard let self, self.request === request else { return }
            self.request = nil
            task = nil
            if !Task.isCancelled { receive(result) }
        }
        task = work
        return work
    }

    package func cancel() {
        let task = task
        request = nil
        self.task = nil
        // The task's cancellation handler owns the NetFS cancel call, including cancellation before it starts.
        task?.cancel()
    }
}

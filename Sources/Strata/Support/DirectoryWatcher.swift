import Foundation

/// Calls `onChange` (debounced, on the main thread) when entries are added to, removed from, or renamed inside a
/// directory.
package nonisolated final class DirectoryWatcher: Sendable {
    private let source: DispatchSourceFileSystemObject

    /// Watchers of those of `urls` that open, opened and watching on a thread of their own before this returns: on a
    /// server that stopped answering, opening a folder waits, and nothing on the main thread waits with it. A change
    /// made after this returns is caught. One dropped stops watching and closes its folder.
    package static func watching(_ urls: [URL], onChange: @escaping @MainActor @Sendable () -> Void) async -> [DirectoryWatcher] {
        let paths = urls.map(\.path)
        return await OwnThread.run { paths.compactMap { DirectoryWatcher(path: $0, onChange: onChange) } }
    }

    private init?(path: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .main)
        let debounce = Debounce(onChange)
        source.setEventHandler { MainActor.assumeIsolated { debounce.schedule() } }
        source.setCancelHandler {
            close(fd)
            MainActor.assumeIsolated { debounce.cancel() }
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// A burst of changes as one call, a moment after the last; none once its watcher has stopped.
@MainActor private final class Debounce {
    private let action: @MainActor @Sendable () -> Void
    private var pending: DispatchWorkItem?
    private var stopped = false

    nonisolated init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    func schedule() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.action()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cancel() {
        stopped = true
        pending?.cancel()
    }
}

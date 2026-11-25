import CoreServices
import Foundation
import StrataIndex
import Synchronization

/// One listing owns both kinds of watch. Dropping it silences even a delivery already queued.
/// The directory watchers report entries added, removed or renamed; the file-event stream adds only what they can't
/// see, a file changing in place. Its files are read as they are now, away from the main thread, a second apart, so
/// a file written for a minute is looked at about once a second.
nonisolated final class ListingWatch: Sendable {
    let ready: Task<Void, Never>
    private let changes: LatestUpdate<Void>
    private let edits: LatestUpdate<Void>
    private struct Sources: Sendable {
        let directories: [DirectoryWatcher]
        let needsPolling: Bool
    }

    private let opened: Task<Sources?, Never>
    private let fallback: Task<Void, Never>
    private static let pollInterval: Duration = .seconds(30)
    private let stream = FSEventsStream()

    typealias StartStream = @Sendable (FSEventsStream, [String]) -> Bool

    typealias OpenDirectories = @Sendable ([URL], @escaping @MainActor @Sendable () -> Void) async -> [DirectoryWatcher]

    enum Effect: Equatable {
        case none
        /// macOS couldn't itemize changes that may include the listing: read it again.
        case reread
        /// A file directly in a watched folder may have changed in place.
        case file(String)
    }

    init(_ folders: [URL], startStream: @escaping StartStream = { $0.start(paths: $1, since: nil, latency: 1) },
         openDirectories: @escaping OpenDirectories = DirectoryWatcher.watching,
         waitForPoll: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: ListingWatch.pollInterval) },
         changed: @escaping @MainActor @Sendable () -> Void,
         poll: (@MainActor @Sendable () -> Void)? = nil,
         hasUnwatchedChildren: (@MainActor @Sendable () -> Bool)? = nil,
         filesChanged: @escaping @MainActor @Sendable ([FileEntry]) -> Void = { _ in }) {
        let schedule: LatestUpdate<Void>.Schedule = { DispatchQueue.main.async(execute: $0) }
        let changes = LatestUpdate<Void>(schedule: schedule) { changed() }
        let edited = EditedFiles()
        let edits = LatestUpdate<Void>(schedule: schedule) {
            let files = edited.take()
            if !files.isEmpty { filesChanged(files) }
        }
        self.changes = changes
        self.edits = edits
        let opened = Task.detached { [stream] () -> Sources? in
            guard !folders.isEmpty, !Task.isCancelled else { return nil }
            let watchers = await openDirectories(folders) { changes.send(()) }
            guard !Task.isCancelled, let paths = await OwnThread.runUnlessCancelled({
                Set(folders.map { PathSpelling.system($0.resolvingSymlinksInPath().path) })
            }), !Task.isCancelled else { return nil }
            stream.handler = { events in
                Self.deliver(events, roots: paths, changed: changes, edited: edited, notifyEdits: edits)
            }
            guard !Task.isCancelled else { return nil }
            let started = startStream(stream, Array(paths))
            return Sources(directories: watchers, needsPolling: !started || watchers.count < folders.count)
        }
        self.opened = opened
        ready = Task { _ = await opened.value }
        fallback = Task { @MainActor in
            guard let sources = await opened.value, sources.needsPolling || hasUnwatchedChildren != nil else { return }
            while !Task.isCancelled {
                do { try await waitForPoll() } catch { return }
                guard !Task.isCancelled else { return }
                if sources.needsPolling || hasUnwatchedChildren?() == true { (poll ?? changed)() }
            }
        }
    }

    private static func deliver(_ events: [FSEventsStream.Event], roots: Set<String>, changed: LatestUpdate<Void>,
                                edited: EditedFiles, notifyEdits: LatestUpdate<Void>) {
        var paths = Set<String>()
        for event in events {
            switch effect(of: event, roots: roots) {
            case .reread: changed.send(()); return
            case .file(let path): paths.insert(path)
            case .none: break
            }
        }
        let files = paths.compactMap { FileEntry(url: URL(filePath: $0, directoryHint: .notDirectory)) }
        guard !files.isEmpty else { return }
        edited.add(files)
        notifyEdits.send(())
    }

    static func effect(of event: FSEventsStream.Event, roots: Set<String>) -> Effect {
        let path = PathSpelling.system(event.path)
        guard path.hasPrefix("/") else { return .none }
        let parent = IndexRefresh.splitPath(path).parent
        if event.invalidatesIndex || event.mustScanSubdirectories {
            let inside = path.hasSuffix("/") ? path : path + "/"
            return roots.contains(path) || roots.contains(parent) || roots.contains { $0.hasPrefix(inside) } ? .reread : .none
        }
        // A folder's own changes are its entries, and the folders in it are entries too: the directory watchers have those.
        let inPlace = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod)
        guard event.flags & inPlace != 0, event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) == 0,
              roots.contains(parent) else { return .none }
        return .file(path)
    }

    /// Whether `current` is a listed file with another size or date than its listing shows. macOS keeps reporting a
    /// file just made as modified for a while, so what was read decides, not the event's flags.
    static func differs(_ listed: FileEntry?, from current: FileEntry) -> Bool {
        guard let listed, !listed.isDirectory else { return false }
        return listed.size != current.size || listed.modified != current.modified
    }

    deinit {
        opened.cancel()
        fallback.cancel()
        changes.cancel()
        edits.cancel()
        // Start and stop must never race; neither waits on the presentation's thread.
        Task.detached { [opened, stream] in
            _ = await opened.value
            stream.stop()
        }
    }
}

/// Files read since the last delivery, the newest reading of each.
private nonisolated final class EditedFiles: Sendable {
    private let files = Mutex<[String: FileEntry]>([:])

    func add(_ read: [FileEntry]) {
        files.withLock { files in for file in read { files[file.locationKey] = file } }
    }

    func take() -> [FileEntry] {
        files.withLock { files in
            defer { files = [:] }
            return Array(files.values)
        }
    }
}

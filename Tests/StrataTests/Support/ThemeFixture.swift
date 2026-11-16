import Foundation
import Synchronization
@testable import StrataTheme

nonisolated enum ThemeFixture {
    /// A theme file of the user's in the bundled format, deriving its colors from a seed.
    static func file(id: String = "meadow", name: String = "Meadow", order: Int = 150,
                     changing: [String: Any] = [:]) throws -> ThemeCatalog.File {
        var values: [String: Any] = [
            "version": 1, "id": id, "name": name, "comment": "Color theme: soft yellow-green",
            "order": order, "seed": [0.45, 0.60, 0.25], "tintStrength": 0.5,
            "lightnessShift": ["light": 0.0, "dark": -0.02],
        ]
        values.merge(changing) { _, new in new }
        return (id + ".json", try JSONSerialization.data(withJSONObject: values))
    }
}

/// A themes folder in memory: what a read of it finds, how often it was read, and whether ever on the main thread.
nonisolated final class ThemeFolderInMemory: Sendable {
    private struct State {
        /// Nil while the folder can't be listed.
        var found: ThemeCatalog.FolderRead?
        var reads = 0
        var wasReadOnTheMainThread = false
        var whileReading: (@Sendable (Int) -> Void)?
    }

    private let state: Mutex<State>

    init(_ files: [ThemeCatalog.File] = []) { state = Mutex(State(found: ThemeCatalog.FolderRead(files: files))) }

    var reads: Int { state.withLock { $0.reads } }
    var wasReadOnTheMainThread: Bool { state.withLock { $0.wasReadOnTheMainThread } }

    /// `unread`: the names of theme files that are there and can't be read.
    func hold(_ files: [ThemeCatalog.File], unread: [String] = []) {
        state.withLock { $0.found = ThemeCatalog.FolderRead(files: files, unread: unread) }
    }

    func refuseToBeListed() { state.withLock { $0.found = nil } }

    /// Runs `action` on the reading thread during each read, with the read's number from one, after what that read
    /// finds is settled: what it changes is for the next read to find.
    func whileReading(_ action: (@Sendable (Int) -> Void)?) { state.withLock { $0.whileReading = action } }

    var reader: UserThemes.Reader {
        { [self] _ in
            let (found, number, action) = state.withLock { state in
                state.reads += 1
                if Thread.isMainThread { state.wasReadOnTheMainThread = true }
                return (state.found, state.reads, state.whileReading)
            }
            action?(number)
            return found
        }
    }
}

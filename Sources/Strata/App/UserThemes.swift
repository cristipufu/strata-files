import Foundation
import StrataSupport
import Synchronization

/// The color themes people add without rebuilding Strata: `<id>.json` files in the bundled format, in a folder of
/// their own. The folder is read on a thread that may wait on its disk, never the main one. Until it has been read,
/// the theme chosen last time comes from the copy of its file kept with that choice, so the first window is drawn
/// in it without the disk being asked. A folder or a file that could not be read says nothing: what was last known
/// of it stands.
nonisolated package final class UserThemes: Sendable {
    /// The app's. It reads nothing until the executable says where the folder is: tests, which only import the
    /// module, read no one's own themes.
    package static let shared = UserThemes(besides: [.system] + ThemeCatalog.bundled)

    package typealias Reader = @Sendable (URL) -> ThemeCatalog.FolderRead?

    private struct State {
        var folder: URL?
        var themes: [ColorTheme] = []
        /// The files `themes` were read from, by name.
        var files: [String: Data] = [:]
        /// Once the folder has been asked about, only it says which themes there are.
        var hasAskedFolder = false
        var isReading = false
        /// Whoever asked about the folder while it was being read, and reads it next: what the read under way finds
        /// may be older than the asking.
        var nextReader: CheckedContinuation<URL?, Never>?
    }

    private static let keptFileKey = "colorThemeFile"
    private let state: Mutex<State>
    private let taken: [ColorTheme]
    private let reader: Reader

    /// `taken`: the themes whose IDs and names a theme of the user's may not repeat.
    package init(folder: URL? = nil, besides taken: [ColorTheme], reader: @escaping Reader = ThemeCatalog.read(folder:)) {
        state = Mutex(State(folder: folder))
        self.taken = taken
        self.reader = reader
    }

    package func useApplicationFolder() {
        state.withLock {
            $0.folder = URL.applicationSupportDirectory.appending(path: "Strata/Themes", directoryHint: .isDirectory)
        }
    }

    /// The themes as last read, in their order. Until the folder has been read: the one kept with the choice of it.
    package var themes: [ColorTheme] { state.withLock { $0.themes } }

    package func theme(withID id: String) -> ColorTheme? {
        state.withLock { $0.themes.first { $0.rawValue == id } }
    }

    private static func fileName(ofThemeWithID id: String) -> String { id + ".json" }

    /// Takes the theme chosen in `defaults` from the copy of its file kept there, checked like a file of the folder.
    /// Only until the folder is asked about: what it holds is what counts from then on.
    package func rememberChoice(in defaults: UserDefaults) {
        guard let file = defaults.data(forKey: Self.keptFileKey) else { return }
        let name = Self.fileName(ofThemeWithID: ColorThemeOptions.chosenID(in: defaults))
        let kept = ThemeCatalog.accepted([(name, file)], besides: taken)
        state.withLock { state in
            guard !state.hasAskedFolder else { return }
            (state.themes, state.files) = kept
        }
    }

    /// Keeps a copy of `theme`'s file in `defaults` for the next launch, and none for a theme that is no theme of
    /// the user's known here.
    package func keepFile(of theme: ColorTheme, in defaults: UserDefaults) {
        let file = state.withLock { $0.files[Self.fileName(ofThemeWithID: theme.rawValue)] }
        defaults.set(file, forKey: Self.keptFileKey)
    }

    /// Reads the folder and says whether its themes are other than those known, so whoever asked tells of what its
    /// own read found. One read is under way at a time, and a folder that stopped answering holds one thread: the
    /// first to ask meanwhile reads once that read has ended, and anyone else is told at once that nothing is theirs
    /// to tell, since that next read covers their asking too.
    package func read() async -> Bool {
        guard let folder = await turnToRead() else { return false }
        let found = await OwnThread.run { [self] in themes(in: folder) }
        let changed = found.map(take) ?? false
        endTurn(passing: folder)
        return changed
    }

    /// The folder to read, now or once the read under way has ended; nil for a store that has none, or when another
    /// already waits to read.
    private func turnToRead() async -> URL? {
        await withCheckedContinuation { waiting in
            let answer: URL?? = state.withLock { state in
                guard let folder = state.folder else { return .some(nil) }
                state.hasAskedFolder = true
                guard state.isReading else {
                    state.isReading = true
                    return folder
                }
                guard state.nextReader == nil else { return .some(nil) }
                state.nextReader = waiting
                return nil
            }
            if let answer { waiting.resume(returning: answer) }
        }
    }

    /// Lets whoever waits read `folder` next, or ends reading.
    private func endTurn(passing folder: URL) {
        let next = state.withLock { state in
            let next = state.nextReader
            state.nextReader = nil
            state.isReading = next != nil
            return next
        }
        next?.resume(returning: folder)
    }

    /// The themes of `folder` as a read finds them, or nil when it could not be listed. A file that is there and
    /// could not be read stays as it was last known.
    private func themes(in folder: URL) -> (themes: [ColorTheme], files: [String: Data])? {
        guard let found = reader(folder) else { return nil }
        let lastKnown = state.withLock { state in
            found.unread.compactMap { name in state.files[name].map { (name: name, data: $0) } }
        }
        return ThemeCatalog.accepted((found.files + lastKnown).sorted { $0.name < $1.name }, besides: taken)
    }

    private func take(_ found: (themes: [ColorTheme], files: [String: Data])) -> Bool {
        state.withLock { state in
            let changed = found.themes != state.themes
            (state.themes, state.files) = found
            return changed
        }
    }
}

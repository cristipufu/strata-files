import AppKit

/// What a pane's commands need of the pane they run in: its environment, settings and window, the folder they act
/// on, its one slot for command work, and what happens once that folder is listed again.
@MainActor protocol BrowserCommandContext: AnyObject {
    var services: BrowserServices { get }
    var preferences: Prefs { get }
    var commandWindow: NSWindow? { get }
    var targetDirectory: URL? { get }
    var commandWork: Task<Void, Never>? { get set }
    /// Selects `urls` once the folder shows them, listing it again now.
    func selectWhenShown(_ urls: [URL])
    func renameWhenShown(_ url: URL, in directory: URL)
    func refresh()
    /// Copies or moves `urls` into `target` through the pane's queue (onto a server, its server commands).
    func transfer(_ urls: [URL], into target: URL, move: Bool)
}

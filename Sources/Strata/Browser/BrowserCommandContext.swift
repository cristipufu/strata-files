import AppKit

/// Local commands receive their file owner separately, so the shared pane surface carries only presentation and work.
@MainActor protocol PaneCommandContext: AnyObject {
    var commandWindow: NSWindow? { get }
    var targetDirectory: URL? { get }
    var commandWork: Task<Void, Never>? { get set }
    /// Selects `urls` once the folder shows them, listing it again now.
    func selectWhenShown(_ urls: [URL])
    func renameWhenShown(_ url: URL, in directory: URL)
    func refresh()
}

@MainActor protocol BrowserCommandContext: PaneCommandContext {
    var services: BrowserServices { get }
    var preferences: Prefs { get }
    /// Copies or moves `urls` into `target` through the pane's queue (onto a server, its server commands).
    func transfer(_ urls: [URL], into target: URL, move: Bool)
}

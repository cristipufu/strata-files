import AppKit
import StrataModel
import Quartz

/// One preview per service environment, with a weak originating pane. Selection changes explicitly replace its root.
@MainActor final class PreviewCoordinator: NSObject, NSWindowDelegate {
    private let preferences: Prefs
    private let directories: DirectoryReader
    private let copies: CopyProviders
    private let thumbnails: FileThumbnails
    private let clipboard: Clipboard
    private let openFile: (URL) -> Void
    private let presentPanel: (NSPanel, NSView) -> Bool
    private weak var owner: BrowserViewController?
    private var ownerID: ObjectIdentifier?
    private var ownerRevision = 0
    private var rootKey: String?
    private let passwordPrompt = PreviewPasswordPrompt()
    private(set) var panel: NSPanel?
    private(set) var content: PreviewBrowserController?

    var isOpen: Bool { content != nil }

    init(preferences: Prefs, directories: DirectoryReader, copies: CopyProviders, thumbnails: FileThumbnails,
         clipboard: Clipboard, openFile: @escaping (URL) -> Void, presentPanel: @escaping (NSPanel, NSView) -> Bool) {
        self.preferences = preferences
        self.directories = directories
        self.copies = copies
        self.thumbnails = thumbnails
        self.clipboard = clipboard
        self.openFile = openFile
        self.presentPanel = presentPanel
        super.init()
    }

    isolated deinit { close() }

    func show(_ entry: FileEntry, from browser: BrowserViewController, present: Bool = true) {
        if content == nil {
            let session = PreviewSession(reader: directories, isPlaceholder: { [copies] in copies.isPlaceholder($0) })
            session.archiveAccess.requestPassword = { [weak self] name in
                guard let prompt = self?.passwordPrompt else { return nil }
                return await prompt.request(name, in: self?.panel)
            }
            session.archiveAccess.cancelPassword = { [weak self] in self?.passwordPrompt.cancel() }
            let content = PreviewBrowserController(session: session, preferences: preferences, thumbnails: thumbnails, copies: copies, clipboard: clipboard)
            let panel = PreviewPanel(contentRect: NSRect(origin: .zero, size: PreviewLayout.defaultSize),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.contentViewController = content
            let screen = browser.viewIfLoaded?.window?.screen ?? NSScreen.main
            let available = screen.map { panel.contentRect(forFrameRect: $0.visibleFrame).size } ?? PreviewLayout.defaultSize
            panel.contentMinSize = PreviewLayout.contentSize(PreviewLayout.minimumSize, available: available)
            panel.setContentSize(PreviewLayout.contentSize(preferences.previewWindowSize, available: available))
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            }
            panel.delegate = self
            panel.onClose = { [weak self] in self?.close() }
            content.outline.onClose = { [weak self] in self?.close() }
            content.onAction = { [weak self] action, target in self?.perform(action, target: target) }
            ThemeStyle.bind(panel)
            self.content = content
            self.panel = panel
        }
        owner = browser
        ownerID = ObjectIdentifier(browser)
        ownerRevision = browser.navigationRevision
        rootKey = BrowserListing.key(entry.url)
        content?.session.show(entry, showHidden: preferences.showHidden, applications: browser.applicationFolders)
        if present {
            if let panel {
                guard presentPanel(panel, browser.focusView) else { return close() }
            }
            if panel?.isVisible == true, content?.session.isContainer == true { panel?.makeFirstResponder(content?.focusView) }
        }
    }

    func selectionChanged(in browser: BrowserViewController) {
        guard isOpen, owner === browser else { return }
        let selected = browser.selectedEntries
        guard ownerRevision == browser.navigationRevision, selected.count == 1, let entry = selected.first else { return close() }
        guard BrowserListing.key(entry.url) != rootKey else { return }
        show(entry, from: browser, present: false)
    }

    func perform(_ action: PreviewAction, target: PreviewCommandTarget) {
        guard let browser = owner, browser.navigationRevision == ownerRevision,
              let content, content.canPerform(action, target: target), target.matches(content.session) else { return }
        switch action {
        case .copy where target.entry.map({ copies.contains($0.url) }) == true:
            performProvider(action, target: target, browser: browser, content: content)
        case .open where target.entry.map({ copies.contains($0.url) && !$0.isFolder }) == true:
            performProvider(action, target: target, browser: browser, content: content)
        case .copy where target.entry == nil:
            let clipboardChange = clipboard.pasteboard.changeCount
            content.copyArchiveMember(target) { [weak self, weak content, weak browser] lease in
                guard let self, let content, let browser, owner === browser,
                      browser.navigationRevision == ownerRevision, self.content === content,
                      target.matches(content.session), clipboard.pasteboard.changeCount == clipboardChange else { return }
                lease.keepForClipboard()
                clipboard.write([lease.url], cut: false)
            }
        case .open where target.entry == nil:
            content.openArchiveMember(target) { [weak self, weak content, weak browser] lease in
                guard let self, let content, let browser, owner === browser,
                      browser.navigationRevision == ownerRevision, self.content === content,
                      target.matches(content.session) else { return }
                lease.keepForClipboard()
                openFile(lease.url)
            }
        case .copy:
            guard let entry = target.entry else { return }
            clipboard.write([entry.url], cut: false)
        case .copyPath:
            guard let path = target.path(copies: copies) else { return }
            clipboard.pasteboard.clearContents()
            clipboard.pasteboard.setString(path, forType: .string)
        case .open:
            guard let entry = target.entry else { return }
            if entry.isFolder {
                close()
                browser.delegate?.browser(browser, navigateTo: entry.url)
            } else {
                openFile(entry.url)
            }
        case .showInStrata:
            guard let entry = target.entry else { return }
            close()
            browser.delegate?.browser(browser, reveal: entry.url)
        }
    }

    private func performProvider(_ action: PreviewAction, target: PreviewCommandTarget, browser: BrowserViewController,
                                 content: PreviewBrowserController) {
        let clipboardChange = clipboard.pasteboard.changeCount
        content.providerContent.perform(action, target: target, session: content.session) { [weak self, weak content, weak browser] entry, lease in
            guard let self, let content, let browser, owner === browser, self.content === content,
                  browser.navigationRevision == ownerRevision, target.isActive(in: content.session) else { return }
            if action == .copy {
                guard clipboard.pasteboard.changeCount == clipboardChange, let lease else { return }
                lease.keepForClipboard()
                clipboard.write([lease.url], cut: false)
            } else { openFile(entry.url) }
            content.session.fetched(entry)
        }
    }

    func invalidate(owner browser: BrowserViewController) {
        guard ownerID == ObjectIdentifier(browser) else { return }
        close()
    }

    func close() {
        let browser = owner
        owner = nil
        ownerID = nil
        rootKey = nil
        content?.close()
        content = nil
        let window = panel
        panel = nil
        window?.delegate = nil
        window?.close()
        if browser?.viewIfLoaded?.window?.isKeyWindow == true { browser?.view.window?.makeFirstResponder(browser?.focusView) }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        panel?.delegate = nil
        panel = nil
        close()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        preferences.previewWindowSize = panel.contentRect(forFrameRect: panel.frame).size
    }
}

@MainActor private final class PreviewPanel: NSPanel {
    var onClose: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           (firstResponder as? NSTextView)?.isEditable != true {
            onClose?()
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }
}

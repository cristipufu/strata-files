import AppKit

/// Full Disk Access detection and the folders macOS guards with consent prompts.
package enum Privacy {
    private static var cachedAccess: Bool?

    /// Reading the TCC database fails silently (no prompt) without Full Disk Access, which makes it a safe probe.
    package static var hasFullDiskAccess: Bool {
        if let cachedAccess { return cachedAccess }
        let probe = Places.home.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd) }
        cachedAccess = fd >= 0
        return fd >= 0
    }

    package static func refresh() {
        cachedAccess = nil
    }

    private static let accessibleKey = "accessibleProtectedFolders"

    /// Remembers that a protected folder (e.g. Documents) was opened successfully, so it may be indexed and measured
    /// without another prompt.
    /// Whether this made one of them known: what the index may read has changed then.
    @discardableResult
    package static func markAccessible(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = Places.home.path
        for relative in ["Desktop", "Documents", "Downloads"] {
            let root = home + "/" + relative
            guard path == root || path.hasPrefix(root + "/") else { continue }
            var known = Prefs.shared.defaults.stringArray(forKey: accessibleKey) ?? []
            guard !known.contains(root) else { return false }
            known.append(root)
            Prefs.shared.defaults.set(known, forKey: accessibleKey)
            return true
        }
        return false
    }

    package static func isKnownAccessible(_ path: String) -> Bool {
        (Prefs.shared.defaults.stringArray(forKey: accessibleKey) ?? []).contains(path)
    }

    package static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

    /// Folders that pop a consent prompt (or hold other apps' data) when read without Full Disk Access.
    private static var guardedRoots: [String] {
        let home = Places.home.path
        return ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library",
                "Library/Containers", "Library/Group Containers", "Library/Mobile Documents"]
            .map { home + "/" + $0 } + ["/Volumes"]
    }

    /// Whether walking `url` to measure it could trigger a prompt. Inside a guarded folder you've already opened,
    /// access is granted, so only folders guarded more narrowly than where you're browsing count.
    package static func measuringWouldPrompt(_ url: URL, browsing directory: URL) -> Bool {
        guard !hasFullDiskAccess else { return false }
        let path = url.standardizedFileURL.path
        let current = directory.standardizedFileURL.path
        for root in guardedRoots where path == root || path.hasPrefix(root + "/") {
            if !(current == root || current.hasPrefix(root + "/")) && !isKnownAccessible(root) { return true }
        }
        return false
    }
}

/// Shown once at first launch without Full Disk Access: one explained request instead of a prompt per folder.
package final class WelcomeSheetController: NSWindowController {
    private var timer: Timer?
    private let status = NSTextField(labelWithString: "")
    private let primary = NSButton(title: String(localized: "Open Privacy Settings"), target: nil, action: nil)
    package var onGranted: (() -> Void)?

    package init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: panel)

        let icon = DraggableAppIcon(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.toolTip = String(localized: "Drag into the Full Disk Access list")
        let caption = NSTextField(labelWithString: String(localized: "Drag me into the list", comment: "Welcome sheet: under the app icon"))
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: String(localized: "Welcome to Strata"))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let body = NSTextField(wrappingLabelWithString:
            String(localized: "Give Strata Full Disk Access to see folder sizes everywhere and browse protected places like Library, Mail and other apps’ data, with one switch instead of a permission prompt per folder."))
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 380
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.stringValue = String(localized: "Open Privacy Settings, drag the icon above into the list (or click +) and switch Strata on.")

        primary.bezelStyle = .push
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(openSettings)
        let later = NSButton(title: String(localized: "Not Now"), target: self, action: #selector(dismiss))
        later.bezelStyle = .push
        later.controlSize = .large
        later.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [later, primary])
        buttons.spacing = 10
        status.alignment = .center
        status.lineBreakMode = .byWordWrapping
        status.preferredMaxLayoutWidth = 380
        let stack = NSStackView(views: [icon, caption, title, body, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(2, after: icon)
        stack.setCustomSpacing(14, after: caption)
        stack.setCustomSpacing(18, after: status)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        Privacy.refresh()
        guard Privacy.hasFullDiskAccess else { return }
        timer?.invalidate()
        status.stringValue = String(localized: "✓ Full Disk Access is on. You’re all set.")
        status.textColor = .systemGreen
        primary.isEnabled = false
        onGranted?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.dismiss() }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(Privacy.settingsURL)
    }

    @objc private func dismiss() {
        timer?.invalidate()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        Prefs.shared.defaults.set(true, forKey: "welcomeShown")
    }
}

/// The app icon as a drag source: System Settings accepts it dropped onto the Full Disk Access list.
package final class DraggableAppIcon: NSImageView, NSDraggingSource {
    package override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    package override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    package func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }
}

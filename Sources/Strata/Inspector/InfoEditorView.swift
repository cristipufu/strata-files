import AppKit

/// Get Info's editable part for one item, as three Inspector cards' contents: Spotlight comments, the app that opens it
/// (this file, or Change All…), and Locked plus who may read and write it. Changes apply at once; what's refused says
/// why, in the card it happened in.
@MainActor final class InfoEditor: NSObject, NSTextFieldDelegate, NSMenuDelegate {
    private(set) var url: URL?
    private var isFolder = false
    /// The comment as it was when typing began (Escape goes back to it), and the pending save while typing.
    private var commentBeforeEditing = ""
    // Focus can precede AppKit's first editing notification; keep the displayed item too.
    private var shownCommentChoice: Result<ChosenFile, Error>?
    private var commentChoice: Result<ChosenFile, Error>?
    private var pendingCommentSave: Task<Void, Never>?
    private var savedNoteHide: Task<Void, Never>?

    /// The cards' contents.
    let commentsContent = NSStackView()
    let openWithContent = NSStackView()
    let permissionsContent = NSStackView()
    /// Whether the item has an app to open it with (folders and packages open as themselves).
    private(set) var hasOpenWith = false
    /// What the permission rows were filled from (see `loadPermissions`).
    private var permissionsShown: [String]?

    let comments = NSTextField()
    private let openWith = NSPopUpButton()
    private let changeAll = NSButton(title: String(localized: "Change All…", comment: "Inspector button: open every document of this kind with the chosen app"),
                                     target: nil, action: nil)
    private let openWithNote = NSTextField(wrappingLabelWithString: "")
    private let locked = NSSwitch()
    private let rows = InspectorRows()
    private var accessMenus: [FileInfoEditing.Who: NSPopUpButton] = [:]
    private var whoNames: [FileInfoEditing.Who: String] = [:]
    private let commentsMessage = InfoEditor.messageLabel()
    private let openWithMessage = InfoEditor.messageLabel()
    private let permissionsMessage = InfoEditor.messageLabel()
    private var apps: [OpenWithApp] = []
    /// The app the item opens with now, and its type's name, as last read.
    private var currentApp: URL?
    private var typeName: String?
    private(set) var factsTask: Task<Void, Never>?
    /// The item whose settings the cards show: until the item on show's arrive, no change may be made, since it
    /// would be made from what another item has.
    private var loadedURL: URL?
    private var isLoaded: Bool { loadedURL != nil && loadedURL == url }
    /// The item whose settings are shown, held open as it was read: access changes go to it, never to one put in its
    /// place since.
    private var shownItem: Result<ChosenFile, any Error>?
    private let readFacts: (URL, Bool) async -> Facts
    private var appsTask: Task<Void, Never>?
    /// Whether `apps` lists every app that can open the item (read when the menu opens: it's slow to work out on every
    /// selection change).
    private var appsComplete = false

    private var window: NSWindow? { comments.window ?? openWith.window ?? locked.window }

    isolated deinit {
        pendingCommentSave?.cancel()
        savedNoteHide?.cancel()
        factsTask?.cancel()
        appsTask?.cancel()
    }

    /// What the cards show for an item, read away from the main thread: moving through a folder on a slow disk or a
    /// server mustn't wait on each item's metadata, nor on LaunchServices.
    nonisolated struct Facts: Sendable {
        let choice: Result<ChosenFile, any Error>
        let comment: String
        let isLocked: Bool
        let names: (owner: String, group: String, ownedByYou: Bool)?
        let mode: mode_t?
        let app: OpenWithApp?
        let typeName: String?

        @concurrent static func read(_ url: URL, opensWithApps: Bool) async -> Facts {
            let path = url.path
            return Facts(choice: Result { try ChosenFile(url) }, comment: FileInfoEditing.comment(at: path),
                         isLocked: FileInfoEditing.isLocked(at: path), names: FileInfoEditing.names(at: path),
                         mode: FileInfoEditing.mode(at: path),
                         app: opensWithApps ? NSWorkspace.shared.urlForApplication(toOpen: url).map(OpenWithApp.init) : nil,
                         typeName: opensWithApps ? InfoEditor.typeName(of: url) : nil)
        }
    }

    init(readFacts: @escaping (URL, Bool) async -> Facts) {
        self.readFacts = readFacts
        super.init()
        comments.placeholderString = String(localized: "Add Comments", comment: "Placeholder of the Inspector’s Spotlight comments field")
        comments.font = .systemFont(ofSize: 12)
        comments.bezelStyle = .roundedBezel
        comments.lineBreakMode = .byWordWrapping
        comments.usesSingleLineMode = false
        comments.cell?.wraps = true
        comments.cell?.isScrollable = false
        comments.maximumNumberOfLines = 4
        comments.delegate = self
        comments.setAccessibilityLabel(String(localized: "Comments", comment: "Inspector: the item’s Spotlight comments"))
        ThemeStyle.bind(comments, to: .preview)

        openWith.target = self
        openWith.action = #selector(openWithChanged(_:))
        openWith.setAccessibilityLabel(String(localized: "Open With"))
        openWith.menu?.delegate = self
        openWith.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changeAll.target = self
        changeAll.action = #selector(changeAllClicked(_:))
        changeAll.controlSize = .small
        changeAll.bezelStyle = .push
        changeAll.toolTip = String(localized: "Open all documents like this one with this app")
        openWithNote.font = .systemFont(ofSize: 11)
        openWithNote.textColor = InspectorColors.secondary
        openWithNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        locked.controlSize = .mini
        locked.target = self
        locked.action = #selector(lockedChanged(_:))
        locked.setAccessibilityLabel(String(localized: "Locked", comment: "Inspector checkbox: the item is locked against changes"))
        for who in FileInfoEditing.Who.allCases {
            let menu = NSPopUpButton()
            menu.controlSize = .small
            menu.font = .systemFont(ofSize: 12)
            // Truncates ("Write Only (Dro…") rather than holding the Inspector wider than you set it.
            menu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            menu.target = self
            menu.action = #selector(accessChanged(_:))
            menu.tag = who.rawValue
            accessMenus[who] = menu
        }

        for stack in [commentsContent, openWithContent, permissionsContent] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
        }
        commentsContent.setViews([comments, commentsMessage], in: .top)
        let noteRow = NSStackView(views: [openWithNote, NSView(), changeAll])
        noteRow.alignment = .firstBaseline
        noteRow.spacing = 8
        openWithContent.setViews([openWith, noteRow, openWithMessage], in: .top)
        permissionsContent.setViews([rows, permissionsMessage], in: .top)
        NSLayoutConstraint.activate([
            comments.widthAnchor.constraint(equalTo: commentsContent.widthAnchor),
            // Room for a few lines: comments are often sentences.
            comments.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            commentsMessage.widthAnchor.constraint(equalTo: commentsContent.widthAnchor),
            openWith.widthAnchor.constraint(equalTo: openWithContent.widthAnchor),
            noteRow.widthAnchor.constraint(equalTo: openWithContent.widthAnchor),
            openWithMessage.widthAnchor.constraint(equalTo: openWithContent.widthAnchor),
            rows.widthAnchor.constraint(equalTo: permissionsContent.widthAnchor),
            permissionsMessage.widthAnchor.constraint(equalTo: permissionsContent.widthAnchor),
        ])
    }

    private static func messageLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = InspectorColors.error
        label.isHidden = true
        return label
    }

    /// Shows `entry`'s settings. Showing the same item again refreshes them, leaving a comment being typed alone.
    func show(_ entry: FileEntry) {
        let same = url == entry.url
        // Moving on while a comment is being typed keeps it (for the item it was typed for).
        if !same, let previous = url, comments.currentEditor() != nil {
            pendingCommentSave?.cancel()
            saveComment(comments.stringValue, at: previous.path, choice: commentChoice ?? shownCommentChoice)
            window?.makeFirstResponder(nil)
        }
        if !same {
            pendingCommentSave?.cancel()
            commentChoice = nil
        }
        url = entry.url
        isFolder = entry.isDirectory
        // Folders open in Strata; apps and other packages open as themselves.
        hasOpenWith = !entry.isDirectory
        if !same {
            [commentsMessage, openWithMessage, permissionsMessage].forEach { $0.isHidden = true }
            // Until the new item's settings arrive, nothing here may be changed: it would change the old one.
            loadedURL = nil
            shownItem = nil
            shownCommentChoice = nil
            comments.stringValue = ""
            showPermissions(nil, nil)
            apps = []
            currentApp = nil
            typeName = nil
            appsTask?.cancel()
            appsTask = nil
            setEnabled(false)
        }
        factsTask?.cancel()
        let url = entry.url, opensWithApps = hasOpenWith, readFacts = readFacts
        factsTask = Task { [weak self] in
            let facts = await readFacts(url, opensWithApps)
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.apply(facts, same: same)
        }
    }

    private func apply(_ facts: Facts, same: Bool) {
        loadedURL = url
        shownItem = facts.choice
        if !same || comments.currentEditor() == nil {
            shownCommentChoice = facts.choice
            comments.stringValue = facts.comment
        }
        locked.state = facts.isLocked ? .on : .off
        if hasOpenWith, !same || apps.isEmpty { showApps(current: facts.app, typeName: facts.typeName) }
        showPermissions(facts.names, facts.mode, onlyIfChanged: true)
        setEnabled(facts.names?.ownedByYou ?? false)
    }

    func hide() {
        if let previous = url, comments.currentEditor() != nil {
            pendingCommentSave?.cancel()
            saveComment(comments.stringValue, at: previous.path, choice: commentChoice ?? shownCommentChoice)
            window?.makeFirstResponder(nil)
        }
        pendingCommentSave?.cancel()
        savedNoteHide?.cancel()
        factsTask?.cancel()
        appsTask?.cancel()
        appsTask = nil
        loadedURL = nil
        shownItem = nil
        shownCommentChoice = nil
        commentChoice = nil
        url = nil
    }

    /// A locked item takes no changes but unlocking; only its owner can lock or unlock it.
    private func setEnabled(_ ownedByYou: Bool) {
        let isLocked = locked.state == .on
        let loaded = isLoaded
        comments.isEditable = loaded && !isLocked
        comments.isEnabled = loaded && !isLocked
        openWith.isEnabled = loaded && !isLocked && !apps.isEmpty
        changeAll.isEnabled = loaded && !isLocked && !apps.isEmpty
        locked.isEnabled = loaded && ownedByYou
        for menu in accessMenus.values { menu.isEnabled = loaded && ownedByYou && !isLocked }
    }

    // MARK: - Open With

    private func showApps(current: OpenWithApp?, typeName: String?) {
        // Just the current app for now; the rest when the menu opens.
        apps = current.map { [$0] } ?? []
        currentApp = current?.url
        self.typeName = typeName
        appsComplete = false
        fillAppMenu()
        openWithNote.stringValue = typeName.map {
            String(localized: "For this file. Change All… sets it for every “\($0)”.", comment: "Inspector, under Open With: a kind of document")
        } ?? String(localized: "For this file. Change All… sets it for every document like it.")
    }

    /// The rest of the apps load while the menu is open, and appear in it when they arrive.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openWith.menu, !appsComplete, appsTask == nil, let url else { return }
        appsTask = Task { [weak self] in
            let found = await OpenWithApp.all(opening: url, limit: 40)
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.appsTask = nil
            self.appsComplete = true
            self.apps = self.apps.filter { app in !found.contains { $0.url == app.url } } + found
            self.fillAppMenu()
        }
    }

    private func fillAppMenu() {
        openWith.removeAllItems()
        if apps.isEmpty {
            openWith.addItem(withTitle: String(localized: "No App", comment: "Inspector Open With menu: no app can open the item"))
            openWith.isEnabled = false
            changeAll.isEnabled = false
            return
        }
        for app in apps {
            let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
            item.image = app.image
            item.representedObject = app.url
            openWith.menu?.addItem(item)
        }
        if let currentApp, let index = apps.firstIndex(where: { $0.url == currentApp }) {
            openWith.selectItem(at: index)
        }
        let enabled = isLoaded && locked.state == .off
        openWith.isEnabled = enabled
        changeAll.isEnabled = enabled
    }

    @objc private func openWithChanged(_ sender: NSPopUpButton) {
        guard isLoaded, let url, let app = sender.selectedItem?.representedObject as? URL else { return }
        // Picking the app it already opens with changes nothing (and mustn't pin this file to it).
        guard app != currentApp else { return }
        let targetURL = url
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: url) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.url == targetURL else { return }
                if error == nil { self.currentApp = app }
                self.finish(error, in: self.openWithMessage)
            }
        }
    }

    /// Strata's name for a document it knows, as its Kind says; otherwise the system's, since Change All acts on the
    /// file's type and a Kind of Strata's own, such as a small `.ts` file's TypeScript, names no type.
    nonisolated static func typeName(of url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .contentTypeKey])
        return KnownDocument.kind(extension: url.pathExtension, type: values?.contentType)?.name
            ?? values?.localizedTypeDescription
    }

    @objc private func changeAllClicked(_ sender: Any?) {
        guard isLoaded, let url, let app = openWith.selectedItem?.representedObject as? URL, let window else { return }
        let kind = typeName
        let alert = NSAlert()
        let appName = apps.first { $0.url == app }?.name ?? app.deletingPathExtension().lastPathComponent
        alert.messageText = kind.map { String(localized: "Open every “\($0)” with “\(appName)”?", comment: "A kind of document (“PDF document”), then an app") }
            ?? String(localized: "Open every document like this one with “\(appName)”?")
        alert.informativeText = String(localized: "This changes the app macOS uses for every document of this kind, in Finder too.")
        alert.addButton(withTitle: String(localized: "Change All", comment: "Alert button: open every document of this kind with the chosen app"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let targetURL = url
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenContentTypeOfFileAt: url) { error in
                DispatchQueue.main.async {
                    guard let self, self.url == targetURL else { return }
                    self.finish(error, in: self.openWithMessage)
                }
            }
        }
    }

    // MARK: - Comments
    //
    // A comment saves as you type (a moment after you stop) and when you leave the field; Return finishes (the field
    // lets go, so you can see it's done), Option-Return starts a new line, Escape puts back what was there. "Saved"
    // shows briefly after each save.

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard url != nil else { return }
        commentChoice = shownCommentChoice
        commentBeforeEditing = comments.stringValue
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let path = url?.path else { return }
        if commentChoice == nil { commentChoice = shownCommentChoice }
        pendingCommentSave?.cancel()
        pendingCommentSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.saveComment(self.comments.stringValue, at: path)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        pendingCommentSave?.cancel()
        guard let url else { return }
        saveComment(comments.stringValue, at: url.path)
        commentChoice = nil
        shownCommentChoice = Result { try ChosenFile(url) }
        comments.stringValue = FileInfoEditing.comment(at: url.path)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === comments else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            pendingCommentSave?.cancel()
            comments.stringValue = commentBeforeEditing
            if let url { saveComment(commentBeforeEditing, at: url.path) }
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    private func saveComment(_ text: String, at path: String, choice: Result<ChosenFile, Error>? = nil) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != FileInfoEditing.comment(at: path) else { return }
        do {
            guard let choice = choice ?? commentChoice else { return }
            let chosen = try choice.get()
            guard chosen.url.path == path else { throw POSIXError(.ESTALE) }
            try FileInfoEditing.setComment(text, on: chosen)
            finish(nil, in: commentsMessage)
            // Only for the item on show (a save for the one just left says nothing here).
            if path == url?.path { showSaved() }
        } catch {
            finish(error, in: commentsMessage)
        }
    }

    private func showSaved() {
        commentsMessage.textColor = InspectorColors.secondary
        commentsMessage.stringValue = String(localized: "Saved", comment: "Inspector, under Comments: the comment was saved")
        commentsMessage.isHidden = false
        savedNoteHide?.cancel()
        savedNoteHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.commentsMessage.textColor == InspectorColors.secondary else { return }
            self.commentsMessage.isHidden = true
        }
    }

    // MARK: - Locked and permissions

    @objc private func lockedChanged(_ sender: NSSwitch) {
        guard isLoaded, let url else { return }
        do {
            try FileInfoEditing.setLocked(sender.state == .on, at: url.path)
            finish(nil, in: permissionsMessage)
        } catch {
            finish(error, in: permissionsMessage)
        }
        locked.state = FileInfoEditing.isLocked(at: url.path) ? .on : .off
        loadPermissions(url.path)
        setEnabled(FileInfoEditing.names(at: url.path)?.ownedByYou ?? false)
    }

    /// Fills the Locked switch and the access menus. `onlyIfChanged` (a refresh) leaves them alone when the owner,
    /// group, mode and lock are what they show already; after a change they're always filled again, so a refused
    /// change puts the menu back.
    private func loadPermissions(_ path: String) {
        showPermissions(FileInfoEditing.names(at: path), FileInfoEditing.mode(at: path))
    }

    private func showPermissions(_ names: (owner: String, group: String, ownedByYou: Bool)?, _ mode: mode_t?,
                                 onlyIfChanged: Bool = false) {
        guard let path = url?.path, let names, let mode else {
            permissionsShown = nil
            rows.set([])
            return
        }
        let shown = [path, names.owner, names.group, "\(names.ownedByYou)", "\(mode)", "\(isFolder)", "\(locked.state.rawValue)"]
        if onlyIfChanged, shown == permissionsShown { return }
        permissionsShown = shown
        whoNames[.owner] = names.ownedByYou
            ? String(localized: "\(names.owner) (Me)", comment: "Sharing & Permissions: the owner’s account name when it’s you") : names.owner
        whoNames[.group] = names.group
        whoNames[.everyone] = String(localized: "everyone", comment: "Sharing & Permissions: everyone else (as Finder’s Get Info writes it)")
        // Only the owner may change them (and nothing changes while it's locked).
        let editable = names.ownedByYou && locked.state == .off
        var list: [(String, NSView)] = [(String(localized: "Locked", comment: "Inspector checkbox: the item is locked against changes"), locked)]
        for who in FileInfoEditing.Who.allCases {
            guard let menu = accessMenus[who] else { continue }
            let current = FileInfoEditing.access(mode, for: who)
            menu.removeAllItems()
            // A drop box is for folders; a file shows it only when it's already set that way.
            for access in FileInfoEditing.Access.allCases where access != .writeOnly || isFolder || current == .writeOnly {
                menu.addItem(withTitle: access.title)
                menu.lastItem?.tag = access.rawValue
            }
            menu.selectItem(withTag: current.rawValue)
            menu.isEnabled = editable
            let name = whoNames[who] ?? ""
            menu.setAccessibilityLabel(String(localized: "Access for \(name)", comment: "Accessibility: a permissions menu, then whose access it sets"))
            list.append((name, menu))
        }
        rows.set(list)
    }

    @objc private func accessChanged(_ sender: NSPopUpButton) {
        guard isLoaded, let url, let item = shownItem, let who = FileInfoEditing.Who(rawValue: sender.tag),
              let access = FileInfoEditing.Access(rawValue: sender.selectedTag()) else { return }
        // Taking your own access away from a folder shuts you out of it: ask first.
        if who == .owner, isFolder, access == .none || access == .writeOnly, let window {
            let alert = NSAlert()
            alert.messageText = String(localized: "Remove your own access to “\(url.lastPathComponent)”?")
            alert.informativeText = String(localized: "You won’t be able to open this folder until you give yourself access again.")
            alert.addButton(withTitle: String(localized: "Remove Access"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                // Answered for the item asked about: if another is on show by now, its own settings stay as they are.
                guard let self, self.url == url, isLoaded else { return }
                if response == .alertFirstButtonReturn {
                    apply(access, for: who, to: item, at: url)
                } else {
                    loadPermissions(url.path)
                }
            }
            return
        }
        apply(access, for: who, to: item, at: url)
    }

    private func apply(_ access: FileInfoEditing.Access, for who: FileInfoEditing.Who,
                       to item: Result<ChosenFile, any Error>, at url: URL) {
        do {
            try FileInfoEditing.setAccess(access, for: who, of: item.get())
            finish(nil, in: permissionsMessage)
        } catch {
            finish(error, in: permissionsMessage)
        }
        loadPermissions(url.path)
    }

    /// Clears or shows the last change's problem, in the card it happened in.
    private func finish(_ error: Error?, in label: NSTextField?) {
        guard let label else { return }
        label.textColor = InspectorColors.error
        label.stringValue = error.map { String(localized: "Couldn’t change that: \($0.localizedDescription)", comment: "Inspector: a change was refused, then why") } ?? ""
        label.isHidden = error == nil
        if error != nil, label === openWithMessage, let currentApp,
           let index = apps.firstIndex(where: { $0.url == currentApp }) {
            openWith.selectItem(at: index)
        }
    }
}

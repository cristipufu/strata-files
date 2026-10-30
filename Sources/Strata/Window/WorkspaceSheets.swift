import AppKit

/// Save Workspace: a name, and the tabs and panes that will be saved (each folder with its view), so it's clear what
/// reopens. Saving under a name that's taken says it replaces that workspace.
final class SaveWorkspaceController: NSViewController, NSTextFieldDelegate {
    private let workspaces: Workspaces
    private weak var window: NSWindow?
    /// The tabs as the sheet opened; saving reads them again (one may have closed meanwhile).
    private let controllers: [BrowserWindowController]
    private let name = NSTextField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)

    init(window: NSWindow, workspaces: Workspaces) {
        self.workspaces = workspaces
        self.window = window
        controllers = workspaces.ownedControllers(of: window)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Save Workspace"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: String(localized: "Reopen these tabs and panes together from the sidebar, ⌘K or Window ▸ Workspaces."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        name.placeholderString = String(localized: "Name", comment: "Placeholder: the new workspace's name")
        name.stringValue = controllers.first?.groupWorkspaceName ?? controllers.first.map { Places.displayName($0.location, copies: $0.services.copies) } ?? ""
        name.delegate = self
        name.setAccessibilityLabel(String(localized: "Workspace name"))

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, cancel, saveButton])
        footer.spacing = 8

        let tabs = tabList()
        let stack = NSStackView(views: [title, hint, name, tabs, note, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(14, after: hint)
        stack.setCustomSpacing(12, after: name)
        stack.setCustomSpacing(16, after: note)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        ThemeStyle.bind(container, to: .content)
        container.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 460),
        ]
        for view in [hint, name, tabs, note, footer] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        NSLayoutConstraint.activate(constraints)
        view = container
        ThemeStyle.refresh(container)
        nameChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(name)
        name.currentEditor()?.selectAll(nil)
    }

    /// One row per tab: its panes' folders, each with the view it's in.
    private func tabList() -> NSView {
        let well = WellView()
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        let shown = controllers.prefix(6)
        for (index, controller) in shown.enumerated() {
            if index > 0 { rows.addArrangedSubview(Self.divider()) }
            rows.addArrangedSubview(row(for: controller))
        }
        if controllers.count > shown.count {
            let more = NSTextField(labelWithString: String(localized: "and \(controllers.count - shown.count) more", comment: "plural"))
            more.font = .systemFont(ofSize: 11)
            more.textColor = .secondaryLabelColor
            rows.addArrangedSubview(Self.divider())
            rows.addArrangedSubview(Self.padded(more))
        }
        well.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            rows.topAnchor.constraint(equalTo: well.topAnchor, constant: 2),
            rows.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -2),
        ])
        for view in rows.arrangedSubviews { view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
        return well
    }

    private func row(for controller: BrowserWindowController) -> NSView {
        let panes = zip(controller.snapshot, controller.snapshotModes).map { path, mode -> NSView in
            let url = URL(fileURLWithPath: path)
            let icon = NSImageView(image: IconCache.shared.icon(forPath: path, folder: true))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let label = NSTextField(labelWithString: Places.displayName(url, copies: controller.services.copies))
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let viewMode = BrowserViewMode(rawValue: mode) ?? .list
            let modeIcon = NSImageView(image: viewMode.image)
            modeIcon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
            modeIcon.contentTintColor = .tertiaryLabelColor
            modeIcon.toolTip = viewMode.title
            let pane = NSStackView(views: [icon, label, modeIcon])
            pane.spacing = 5
            pane.toolTip = Format.tildePath(url)
            return pane
        }
        var views = [NSView]()
        for (index, pane) in panes.enumerated() {
            if index > 0 {
                let bar = NSBox()
                bar.boxType = .separator
                bar.heightAnchor.constraint(equalToConstant: 14).isActive = true
                views.append(bar)
            }
            views.append(pane)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        let line = NSStackView(views: views)
        line.spacing = 10
        if panes.count > 1 { panes[0].widthAnchor.constraint(equalTo: panes[1].widthAnchor).isActive = true }
        return Self.padded(line)
    }

    private static func padded(_ view: NSView) -> NSView {
        let box = NSStackView(views: [view])
        box.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        return box
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    func controlTextDidChange(_ notification: Notification) { nameChanged() }

    /// Save, or Replace (with when the other was saved) when the name is taken.
    private func nameChanged() {
        let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = !typed.isEmpty
        if let existing = typed.isEmpty ? nil : workspaces.named(typed) {
            saveButton.title = String(localized: "Replace", comment: "Button: save over the workspace with this name")
            note.stringValue = existing.saved.map {
                String(localized: "Replaces the workspace “\(existing.name)” saved \(Format.date($0)).", comment: "The date reads like “Yesterday at 9:41”")
            } ?? String(localized: "Replaces the workspace “\(existing.name)”.")
            note.isHidden = false
        } else {
            saveButton.title = String(localized: "Save", comment: "Button: save the workspace")
            note.isHidden = true
        }
    }

    @objc private func save(_ sender: Any?) {
        let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return Sounds.beep() }
        // Saving over one keeps its name as it was written.
        let saved = workspaces.named(typed)?.name ?? typed
        let current = window.map(workspaces.ownedControllers(of:)) ?? []
        dismiss(nil)
        guard !current.isEmpty else { return }
        workspaces.save(Workspaces.workspace(named: saved, of: current), from: current)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(nil)
    }
}

/// Shown while a workspace connects to the network shares its folders are on; Cancel stops it.
final class WorkspaceConnectController: NSViewController {
    private(set) var isCancelled = false
    /// Stops the connection under way.
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override func loadView() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [spinner, label, cancel])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 420),
        ])
        view = container
    }

    /// The workspace waits on its own request; Cancel never disconnects another pane's shared session.
    func connect(_ server: RemoteServer, using browsing: RemoteBrowsing) async throws {
        guard !isCancelled else { throw CancellationError() }
        let request = Task { try await browsing.connect(server) }
        onCancel = { request.cancel() }
        defer { onCancel = nil }
        try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
        guard !isCancelled else { throw CancellationError() }
    }

    /// Which server it's connecting to now.
    func show(_ address: String) {
        _ = view
        label.stringValue = String(localized: "Connecting to \(address)…", comment: "A server address follows")
    }

    @objc private func cancel(_ sender: Any?) {
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}

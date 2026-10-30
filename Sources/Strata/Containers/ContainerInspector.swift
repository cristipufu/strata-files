import AppKit

/// The Inspector's cards for a container's files: the container (image, state, ports…) and its mounts, each mount
/// opening where it is in the container or, for a folder of this Mac, there.
final class ContainerInspectorView: NSView {
    /// Shows a folder (in the container's files, or on this Mac).
    var onOpen: ((URL) -> Void)?
    let preferences: Prefs
    let copies: ContainerCopyStore
    let store: ContainerStore
    private let stack = NSStackView()
    private var display: Display?

    private enum Display: Equatable {
        case container(Shown)
        case stack(StackShown)
    }

    /// A Compose project selected in Containers: its containers, and whatever action is running on one of them.
    private struct StackShown: Equatable {
        let project: String
        let engine: String
        let directory: URL?
        let containers: [ContainerInfo]
        let busy: ContainerAction?
    }

    private struct Shown: Equatable {
        let source: ContainerSource
        let top: URL
        let container: ContainerInfo?
        let busy: ContainerAction?
    }

    init(frame: NSRect = .zero, preferences: Prefs = .shared,
         copies: ContainerCopyStore = ContainerCopies.store, store: ContainerStore) {
        self.preferences = preferences
        self.copies = copies
        self.store = store
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The selection (a container's files, or a Compose project's folder). Nil hides the cards. Rebuilt only when
    /// something shown changed.
    func configure(url: URL?) {
        let next: Display?
        if let url, copies.isStack(url) {
            next = stackDisplay(url)
        } else {
            next = url.flatMap(copies.copy(containing:)).map { copy in
                .container(Shown(source: copy.source, top: copy.top, container: store.container(id: copy.source.id),
                                 busy: store.busy[copy.source.id]))
            }
        }
        isHidden = next == nil
        guard next != display else { return }
        display = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch next {
        case .container(let shown):
            addCard(containerCard(shown))
            if let mounts = mountsCard(shown) { addCard(mounts) }
        case .stack(let shown):
            addCard(stackCard(shown))
        case nil:
            break
        }
    }

    private func addCard(_ card: InspectorCard) {
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func containerCard(_ shown: Shown) -> InspectorCard {
        let rows = InspectorRows()
        let state: NSTextField
        if let container = shown.container {
            var list: [(String, String)] = [
                (String(localized: "Image", comment: "Inspector row: a container's image"), container.image),
                (String(localized: "Status", comment: "Inspector row: a container's state (“Up 3 hours”)"), container.status),
                (String(localized: "Engine", comment: "Inspector row: Docker Desktop, OrbStack, Colima…"), shown.source.engineName),
            ]
            if !container.ports.isEmpty {
                list.append((String(localized: "Ports", comment: "Inspector row: a container's published ports"), Self.ports(container.ports)))
            }
            if let created = container.created {
                list.append((String(localized: "Created", comment: "Inspector row: creation date"), Format.longDate(created)))
            }
            list.append((String(localized: "ID", comment: "Inspector row: a container's short ID"), container.shortID))
            rows.setText(list)
            state = shown.busy.map { Self.small(ContainerControl.progress($0), color: InspectorColors.warning) } ?? Self.stateLabel(container)
            let buttons = actions(container, busy: shown.busy)
            let content = NSStackView(views: [rows, buttons])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 10
            rows.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            return InspectorCard(id: "container", title: shown.source.name, symbol: "shippingbox", content: content,
                                 accessory: state, preferences: preferences)
        } else {
            rows.setText([(String(localized: "Engine", comment: "Inspector row: Docker Desktop, OrbStack, Colima…"), shown.source.engineName)])
            state = Self.small(String(localized: "Not available", comment: "Inspector: the container is gone, or its engine isn't running"),
                               color: InspectorColors.secondary)
        }
        return InspectorCard(id: "container", title: shown.source.name, symbol: "shippingbox", content: rows,
                             accessory: state, preferences: preferences)
    }

    private func mountsCard(_ shown: Shown) -> InspectorCard? {
        guard let mounts = shown.container?.mounts, !mounts.isEmpty else { return nil }
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for mount in mounts.sorted(by: { $0.destination < $1.destination }) {
            let row = MountRow(mount, top: shown.top) { [weak self] url in self?.onOpen?(url) }
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let count = Self.small(mounts.count.formatted(), color: InspectorColors.secondary)
        return InspectorCard(id: "containerMounts", title: String(localized: "Mounts", comment: "Inspector section: a container's mounted folders and volumes"),
                             symbol: "externaldrive.connected.to.line.below", content: content, accessory: count,
                             preferences: preferences)
    }

    /// The containers of the Compose project this folder is. Nil when none of them are here.
    private func stackDisplay(_ url: URL) -> Display? {
        let name = url.lastPathComponent
        let containers = store.containers.filter {
            $0.compose?.project.compare(name, options: [.caseInsensitive]) == .orderedSame
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !containers.isEmpty else { return nil }
        let engine = copies.engineFolder(url.deletingLastPathComponent())?.name ?? store.engine?.name ?? ""
        let busy = containers.compactMap { store.busy[$0.id] }.first
        return .stack(StackShown(project: containers.first?.compose?.project ?? name, engine: engine,
                                 directory: StackProjects.workingDirectory(of: url, copies: copies, store: store),
                                 containers: containers, busy: busy))
    }

    /// The same actions as a container (Start, Stop, Restart, Pause, Resume), done to every container they apply to,
    /// plus where the project lives.
    private func stackCard(_ shown: StackShown) -> InspectorCard {
        let rows = InspectorRows()
        var list: [(String, NSView)] = []
        if !shown.engine.isEmpty {
            list.append((String(localized: "Engine", comment: "Inspector row: Docker Desktop, OrbStack, Colima…"), InspectorRows.text(shown.engine)))
        }
        if let directory = shown.directory {
            let path = Format.tildePath(directory)
            let value: NSView
            if StackProjects.existing(directory) != nil {
                let link = LinkButton(path, font: .systemFont(ofSize: 12)) { [weak self] in self?.onOpen?(directory) }
                link.toolTip = String(localized: "Show this folder on your Mac", comment: "Inspector, Mounts: tooltip")
                value = link
            } else {
                value = InspectorRows.text(path)
            }
            list.append((String(localized: "Directory", comment: "Inspector row: the folder a Compose project runs from"), value))
        }
        let described = shown.containers.map { container in
            container.status.isEmpty ? container.name : "\(container.name) — \(container.status)"
        }.joined(separator: "\n")
        list.append((String(localized: "Containers", comment: "Inspector row: the containers in a Compose project"), InspectorRows.text(described)))
        rows.set(list)
        let running = shown.containers.filter(\.isRunning).count
        let state = Self.small(String(localized: "\(running) of \(shown.containers.count) running", comment: "Inspector, Compose: how many services run"),
                               color: running == shown.containers.count ? InspectorColors.success : running == 0 ? InspectorColors.secondary : InspectorColors.warning)
        let buttons = stackActions(shown)
        let content = NSStackView(views: [rows, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        rows.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return InspectorCard(id: "stack", title: shown.project, symbol: "square.stack.3d.up", content: content,
                             accessory: state, preferences: preferences)
    }

    private func stackActions(_ shown: StackShown) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        if let busy = shown.busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView(views: [spinner, Self.small(ContainerControl.progress(busy), color: InspectorColors.secondary)])
            row.spacing = 6
            column.addArrangedSubview(row)
        } else {
            let row = FlowView(spacing: 6, lineSpacing: 6)
            for action in ContainerControl.actions(for: shown.containers) {
                row.add(ActionButton(ContainerControl.title(action), symbol: ContainerControl.symbol(action)) { [weak self] in
                    guard let self else { return }
                    ContainerControl.run(action, on: shown.containers, in: self.window, store: self.store)
                })
            }
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        if let folder = shown.directory.flatMap(StackProjects.existing) {
            let row = FlowView(spacing: 6, lineSpacing: 6)
            let preferences = self.preferences
            let terminal = ActionButton(String(localized: "Open in Terminal", comment: "Menu command: open a shell in the selected folder"), symbol: "terminal") {
                guard let app = preferences.terminalURL else { return Sounds.beep() }
                ProjectEditors.open(folder, with: app)
            }
            terminal.toolTip = String(localized: "Open the project folder in your terminal", comment: "Inspector, a Compose project: tooltip on Open in Terminal")
            row.add(terminal)
            let editors = ProjectEditors.installed()
            if !editors.isEmpty {
                let popup = NSPopUpButton()
                popup.pullsDown = true
                popup.controlSize = .small
                popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                popup.addItem(withTitle: String(localized: "Open With"))
                for app in editors {
                    let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
                    item.representedObject = app
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                    popup.menu?.addItem(item)
                }
                popup.target = self
                popup.action = #selector(openStackWith(_:))
                row.add(popup)
            }
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    @objc private func openStackWith(_ sender: NSPopUpButton) {
        defer { sender.selectItem(at: 0) }
        guard let app = sender.selectedItem?.representedObject as? URL, case .stack(let shown) = display,
              let folder = shown.directory.flatMap(StackProjects.existing) else { return }
        ProjectEditors.open(folder, with: app)
    }

    /// Start, Stop, Restart, Pause or Resume (what applies) and Terminal; a spinner while an action runs.
    private func actions(_ container: ContainerInfo, busy: ContainerAction?) -> NSView {
        if let busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView(views: [spinner, Self.small(ContainerControl.progress(busy), color: InspectorColors.secondary)])
            row.spacing = 6
            return row
        }
        let store = self.store
        var buttons: [NSView] = ContainerAction.allCases.filter { $0.applies(to: container.state) }.map { action in
            ActionButton(ContainerControl.title(action), symbol: ContainerControl.symbol(action)) { [weak self] in
                guard let self else { return }
                ContainerControl.run(action, on: [container], in: self.window, store: store)
            }
        }
        let terminal = ActionButton(String(localized: "Terminal", comment: "Inspector button: a shell in the container"), symbol: "terminal") {
            guard let engine = store.engine, ContainerControl.openTerminal(in: container, at: "/", engine: engine) else { return Sounds.beep() }
        }
        terminal.isEnabled = container.isRunning
        terminal.toolTip = String(localized: "Open a shell in the container, in your terminal", comment: "Inspector: tooltip on Terminal")
        buttons.append(terminal)
        // A narrow Inspector wraps them onto another line.
        let row = FlowView(spacing: 6, lineSpacing: 6)
        buttons.forEach(row.add)
        return row
    }

    /// "8080 → 80/tcp, 5432/tcp": the Mac's port, then the container's.
    static func ports(_ ports: [ContainerPort]) -> String {
        var seen = Set<String>()
        return ports.compactMap { port -> String? in
            let text = port.hostPort.map { "\($0) → \(port.containerPort)/\(port.proto)" } ?? "\(port.containerPort)/\(port.proto)"
            return seen.insert(text).inserted ? text : nil
        }.joined(separator: ", ")
    }

    static func stateLabel(_ container: ContainerInfo) -> NSTextField {
        switch container.state {
        case .running: small(String(localized: "Running", comment: "Container state"), color: InspectorColors.success)
        case .paused: small(String(localized: "Paused", comment: "Container state"), color: InspectorColors.warning)
        case .restarting: small(String(localized: "Restarting", comment: "Container state"), color: InspectorColors.warning)
        default: small(String(localized: "Not Running", comment: "Container state: stopped, exited or created"), color: InspectorColors.secondary)
        }
    }

    /// Detail text truncates rather than holding the Inspector at its width: a dragged divider always wins.
    static func small(_ text: String, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

/// A mount: where it is in the container (opens it), and where it comes from.
private final class MountRow: NSView {
    init(_ mount: ContainerMount, top: URL, open: @escaping (URL) -> Void) {
        super.init(frame: .zero)
        let inside = LinkButton(mount.destination, font: .monospacedSystemFont(ofSize: 12, weight: .regular)) {
            open(ContainerCopies.url(forContainerPath: mount.destination, top: top))
        }
        inside.toolTip = String(localized: "Show it in the container", comment: "Inspector, Mounts: tooltip on a mount's path in the container")
        var details: [NSView] = []
        switch mount.kind {
        case .bind where !mount.source.isEmpty:
            let source = URL(fileURLWithPath: mount.source)
            let text = String(localized: "from \(Format.tildePath(source))", comment: "Inspector, Mounts: the Mac folder a container mounts")
            if mount.source.hasPrefix("/"), FileManager.default.fileExists(atPath: mount.source) {
                let link = LinkButton(text, font: .systemFont(ofSize: 11)) { open(source) }
                link.toolTip = String(localized: "Show this folder on your Mac", comment: "Inspector, Mounts: tooltip")
                details.append(link)
            } else {
                details.append(ContainerInspectorView.small(text, color: InspectorColors.secondary))
            }
        case .bind:
            break
        case .volume:
            details.append(ContainerInspectorView.small(String(localized: "volume \(mount.name ?? mount.source)", comment: "Inspector, Mounts: a named volume"),
                                                        color: InspectorColors.secondary))
        case .tmpfs:
            details.append(ContainerInspectorView.small(String(localized: "in memory", comment: "Inspector, Mounts: a tmpfs mount"), color: InspectorColors.secondary))
        case .other:
            break
        }
        if !mount.isWritable {
            details.append(ContainerInspectorView.small(String(localized: "read-only", comment: "Inspector, Mounts: the container can't change it"),
                                                        color: InspectorColors.tertiary))
        }
        // Where it comes from (a volume's 64-character ID) truncates first; equal priorities leave AppKit to choose.
        if details.count > 1 { details[0].setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal) }
        let detail = NSStackView(views: details)
        detail.orientation = .horizontal
        detail.spacing = 6
        let column = NSStackView(views: [inside] + (details.isEmpty ? [] : [detail]))
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A small button with a symbol that runs a closure.
final class ActionButton: NSButton {
    private let onClick: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        symbolConfiguration = .init(pointSize: 10, weight: .medium)
        target = self
        self.action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick() }
}

/// Text that does something when clicked, styled as a link.
final class LinkButton: NSButton {
    private let onClick: () -> Void

    init(_ title: String, font: NSFont, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: InspectorColors.link])
        alignment = .left
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        target = self
        self.action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func clicked() { onClick() }
}

/// The Compose card, for a folder `docker compose` runs in: its services, which are running, and their files.
final class ComposeInspectorView: NSView {
    /// Shows a container's files.
    var onOpenContainer: ((String) -> Void)?
    let preferences: Prefs
    let store: ContainerStore
    private let stack = NSStackView()
    private var shown: Shown?

    private struct Shown: Equatable {
        let project: String
        let services: [Service]
        let busy: [String]
    }

    struct Service: Equatable {
        let name: String
        /// Its containers (one per replica); none when it hasn't been created.
        let containers: [ContainerInfo]
    }

    static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    init(frame: NSRect = .zero, preferences: Prefs = .shared, store: ContainerStore) {
        self.preferences = preferences
        self.store = store
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The folder shown (nil, or a folder without Compose, hides the card).
    func configure(_ folder: URL?) {
        let next = folder.flatMap { Self.compose(in: $0, store: store) }
        isHidden = next == nil
        guard next != shown else { return }
        shown = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let next else { return }
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        for service in next.services {
            let row = ServiceRow(service, open: { [weak self] id in self?.onOpenContainer?(id) },
                                 act: { [weak self] action, containers in
                guard let self else { return }
                ContainerControl.run(action, on: containers, in: window, store: store)
            })
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        // The whole project: the containers `docker compose` made (Strata doesn't make missing ones).
        let all = next.services.flatMap(\.containers)
        if !all.isEmpty {
            var buttons: [NSView] = []
            for action in [ContainerAction.start, .stop] where all.contains(where: { action.applies(to: $0.state) }) {
                let title = action == .start ? String(localized: "Start All", comment: "Compose card: start every container of the project")
                    : String(localized: "Stop All", comment: "Compose card: stop every container of the project")
                buttons.append(ActionButton(title, symbol: ContainerControl.symbol(action)) { [weak self] in
                    guard let self else { return }
                    ContainerControl.run(action, on: all, in: window, store: store)
                })
            }
            if !next.busy.isEmpty {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                buttons = [spinner]
            }
            let row = FlowView(spacing: 6, lineSpacing: 6)
            buttons.forEach(row.add)
            if let last = content.arrangedSubviews.last { content.setCustomSpacing(10, after: last) }
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: columnOrContent(content).widthAnchor).isActive = true
        }
        let running = next.services.filter { $0.containers.contains(where: \.isRunning) }.count
        let total = next.services.count
        let accessory = ContainerInspectorView.small(String(localized: "\(running) of \(total) running", comment: "Inspector, Compose: how many services run"),
                                                     color: InspectorColors.secondary)
        let card = InspectorCard(id: "compose", title: "Compose", symbol: "square.stack.3d.up", content: content,
                                 accessory: accessory, preferences: preferences)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func columnOrContent(_ view: NSView) -> NSView { view }

    /// The services of the Compose project in `folder`: from its compose file, and the containers `docker compose`
    /// made there. Nil when there's neither.
    /// Compose files' services, by path and modification date (the Inspector refreshes often).
    private static var servicesCache: [String: (modified: Date?, names: [String])] = [:]
    /// Working folders with links resolved, by the path a container gives.
    private static var resolvedCache: [String: String] = [:]

    private static func compose(in folder: URL, store: ContainerStore) -> Shown? {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let containers = store.containers.filter { container in
            guard let directory = container.compose?.workingDirectory else { return false }
            let resolved = resolvedCache[directory] ?? URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
            if resolvedCache.count > 500 { resolvedCache.removeAll() }
            resolvedCache[directory] = resolved
            return resolved == real
        }
        let file = fileNames.lazy.map { folder.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard file != nil || !containers.isEmpty else { return nil }
        var names: [String] = []
        if let file {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached = servicesCache[file.path], cached.modified == modified {
                names = cached.names
            } else {
                names = serviceNames(in: file)
                if servicesCache.count > 200 { servicesCache.removeAll() }
                servicesCache[file.path] = (modified, names)
            }
        }
        for name in containers.compactMap(\.compose?.service) where !names.contains(name) { names.append(name) }
        let services = names.map { name in
            Service(name: name, containers: containers.filter { $0.compose?.service == name }.sorted { $0.name < $1.name })
        }
        let project = containers.first?.compose?.project ?? folder.lastPathComponent
        let busy = containers.map(\.id).filter { store.busy[$0] != nil }
        return Shown(project: project, services: services, busy: busy)
    }

    /// The keys under `services:` in a compose file: enough YAML for the usual layouts (block style, any indent).
    static func serviceNames(in file: URL) -> [String] {
        guard let (data, _) = try? TextFile.readPrefix(file, limit: 1 << 20) else { return [] }
        return serviceNames(String(decoding: data, as: UTF8.self))
    }

    static func serviceNames(_ text: String) -> [String] {
        var names: [String] = []
        var inServices = false
        var indent: Int?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let leading = line.prefix { $0 == " " }.count
            if leading == 0 {
                inServices = trimmed.hasPrefix("services:")
                indent = nil
                continue
            }
            guard inServices else { continue }
            if indent == nil { indent = leading }
            guard leading == indent, let colon = trimmed.firstIndex(of: ":") else { continue }
            var key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let first = key.first, first == key.last, first == "\"" || first == "'" { key = String(key.dropFirst().dropLast()) }
            if !key.isEmpty, key.count <= 200, !key.hasPrefix("<<"), !names.contains(key) { names.append(key) }
            if names.count >= 200 { break }
        }
        return names
    }
}

/// A Compose service: its state, its name, and its containers (each opens its files).
private final class ServiceRow: NSView {
    init(_ service: ComposeInspectorView.Service, open: @escaping (String) -> Void,
         act: @escaping (ContainerAction, [ContainerInfo]) -> Void) {
        super.init(frame: .zero)
        let running = service.containers.contains(where: \.isRunning)
        let dot = NSImageView(image: NSImage(systemSymbolName: running ? "circle.fill" : "circle", accessibilityDescription: nil) ?? NSImage())
        dot.symbolConfiguration = .init(pointSize: 7, weight: .bold)
        dot.contentTintColor = running ? InspectorColors.success : InspectorColors.tertiary
        dot.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: service.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = InspectorColors.primary
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var parts: [NSView] = [dot, name]
        if service.containers.isEmpty {
            parts.append(ContainerInspectorView.small(String(localized: "not created", comment: "Inspector, Compose: a service with no container yet"),
                                                      color: InspectorColors.tertiary))
        }
        for container in service.containers {
            let link = LinkButton(container.name, font: .systemFont(ofSize: 11)) { open(container.id) }
            link.toolTip = [container.status, String(localized: "Show its files", comment: "Inspector, Compose: tooltip on a container")]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            // A container's longer name ("shop-web-1") truncates before its service's.
            link.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            parts.append(link)
        }
        let row = NSStackView(views: parts)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // Start or stop this service's containers.
        let action: ContainerAction? = service.containers.isEmpty ? nil : running ? .stop : .start
        var constraints = [
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let action {
            let button = ActionButton("", symbol: ContainerControl.symbol(action)) { act(action, service.containers) }
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = InspectorColors.secondary
            button.toolTip = ContainerControl.title(action)
            button.setAccessibilityLabel(ContainerControl.title(action) + " " + service.name)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            constraints += [
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -6),
            ]
        } else {
            constraints.append(row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(service.name + ", " + (running ? String(localized: "Running", comment: "Container state")
            : service.containers.isEmpty ? String(localized: "not created", comment: "Inspector, Compose: a service with no container yet")
            : String(localized: "Not Running", comment: "Container state: stopped, exited or created")))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}


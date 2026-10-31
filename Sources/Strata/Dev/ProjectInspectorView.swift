import AppKit

/// The inspector's developer cards for a project folder or repository root: what kind of project it is, git branch
/// and changes, regenerable build artifacts with a Clean button, and runnable scripts.
///
/// Takes data (`configure(_:)` with a `ProjectInfo`); it never scans. Calling `configure` again for the same folder
/// (for example when sizes arrive) updates in place and keeps the checkbox choices.
final class ProjectInspectorView: NSView {
    /// Overrides the built-in confirm-and-trash flow.
    var onClean: (([ProjectArtifact]) -> Void)?
    /// Called after artifacts were moved to the Trash by the built-in flow, so the owner can reload.
    var onDidClean: (([URL]) -> Void)?
    /// Overrides the built-in Run in Terminal.
    var onRunScript: ((ProjectScript) -> Void)?

    private(set) var info: ProjectInfo?
    let preferences: Prefs
    let files: BrowserFileCommands
    private let git: GitStatusStore
    private let stack = NSStackView()
    private var deselected: Set<String> = []
    private var showsAllScripts = false
    private var artifactRows: [String: ArtifactRow] = [:]
    private var artifactsTotalLabel: NSTextField?
    private var cleanButton: NSButton?
    /// The Git card's content and the upstream in its header, so a status change refills just that card.
    private var gitContent: NSStackView?
    private var gitUpstream: String?
    private static let collapsedScriptCount = 6

    init(frame: NSRect = .zero, files: BrowserFileCommands, git: GitStatusStore) {
        self.preferences = files.transfers.preferences
        self.files = files
        self.git = git
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        // Sections meet at the hairline, same as the Inspector's other cards.
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

    func configure(_ info: ProjectInfo?) {
        let previous = self.info
        self.info = info
        guard let info else {
            rebuild()
            return
        }
        if previous?.folder != info.folder {
            deselected = []
            explicitlySelected = []
            showsAllScripts = false
        }
        guard let previous, previous.folder == info.folder, previous.kinds == info.kinds, previous.scripts == info.scripts,
              previous.artifacts.map(\.id) == info.artifacts.map(\.id) else {
            rebuild()
            return
        }
        if previous.git != info.git {
            // Files saved or a commit made: only the git status moved. Refill the Git card and leave the others be,
            // rather than rebuilding every card each time a file in the repository changes.
            guard let git = info.git, let gitContent, git.branch.upstream == gitUpstream else {
                rebuild()
                return
            }
            fillGit(git, into: gitContent)
        }
        updateArtifacts()
    }

    // MARK: - Building

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        artifactRows = [:]
        artifactsTotalLabel = nil
        cleanButton = nil
        gitContent = nil
        gitUpstream = nil
        guard let info else { return }

        // Each part is a card like the Inspector's others, collapsed and expanded the same way.
        if !info.kinds.isEmpty {
            let chips = FlowView(spacing: 6, lineSpacing: 6)
            for kind in info.kinds { chips.add(KindChip(kind)) }
            let content = section()
            add(chips, to: content)
            addCard(id: "project", title: String(localized: "Project", comment: "Inspector section title: the folder's software project (kind, git, build artifacts, scripts)"),
                    symbol: "chevron.left.forwardslash.chevron.right", content: content)
        }
        if let git = info.git { buildGit(git) }
        if !info.artifacts.isEmpty { buildArtifacts(info.artifacts) }
        if !info.scripts.isEmpty { buildScripts(info.scripts) }
        updateArtifacts()
    }

    private func buildGit(_ git: ProjectGitSummary) {
        let upstream = git.branch.upstream.map { label($0, size: 11, color: InspectorColors.tertiary) }
        upstream?.lineBreakMode = .byTruncatingHead
        let content = section()
        fillGit(git, into: content)
        gitContent = content
        gitUpstream = git.branch.upstream
        addCard(id: "git", title: "Git", symbol: "arrow.triangle.branch", content: content, accessory: upstream)
    }

    /// The branch line and the change counts.
    private func fillGit(_ git: ProjectGitSummary, into content: NSStackView) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let branch = BranchLine(git)
        add(branch, to: content, spacingAfter: 7)

        let items = FlowView(spacing: 12, lineSpacing: 4)
        let counts = git.counts
        if git.outcome == .timedOut {
            items.add(StatusItem(nil, String(localized: "Status timed out", comment: "Git status didn't finish in time"), color: InspectorColors.tertiary))
        } else if case .failed = git.outcome {
            items.add(StatusItem(nil, String(localized: "Status unavailable", comment: "Git status couldn't be read"), color: InspectorColors.tertiary))
        } else if counts.isClean {
            items.add(StatusItem(symbol: "checkmark.circle", git.isRepositoryRoot ? String(localized: "Working tree clean", comment: "Git: no uncommitted changes")
                : String(localized: "No changes in this folder", comment: "Git: no uncommitted changes inside the selected folder")))
        } else {
            let entries: [(Int, GitFileState, String)] = [
                (counts.conflicted, .conflicted, String(localized: "\(counts.conflicted) conflicted", comment: "plural")),
                (counts.modified, .modified, String(localized: "\(counts.modified) modified", comment: "plural")),
                (counts.added, .added, String(localized: "\(counts.added) added", comment: "plural")),
                (counts.deleted, .deleted, String(localized: "\(counts.deleted) deleted", comment: "plural")),
                (counts.renamed, .renamed, String(localized: "\(counts.renamed) renamed", comment: "plural")),
                (counts.untracked, .untracked, String(localized: "\(counts.untracked) untracked", comment: "plural")),
            ]
            for (count, state, title) in entries where count > 0 {
                items.add(StatusItem(state.color, title))
            }
            if counts.staged > 0 { items.add(StatusItem(symbol: "tray.full", String(localized: "\(counts.staged) staged", comment: "plural"))) }
        }
        if git.stashCount > 0 { items.add(StatusItem(symbol: "archivebox", String(localized: "\(git.stashCount) stashes", comment: "plural"))) }
        add(items, to: content)
    }

    private func buildArtifacts(_ artifacts: [ProjectArtifact]) {
        let total = label("", size: 11, color: InspectorColors.secondary, monospacedDigits: true)
        artifactsTotalLabel = total
        let content = section()
        for artifact in artifacts {
            let row = ArtifactRow(artifact, selected: isSelected(artifact))
            row.onToggle = { [weak self] on in self?.toggle(artifact, on) }
            artifactRows[artifact.id] = row
            add(row, to: content, spacingAfter: 2)
        }
        let button = NSButton(title: String(localized: "Clean", comment: "Button: move the selected build folders to the Trash"),
                              target: self, action: #selector(cleanClicked))
        button.bezelStyle = .push
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        cleanButton = button
        if let last = content.arrangedSubviews.last { content.setCustomSpacing(10, after: last) }
        add(button, to: content)
        addCard(id: "artifacts", title: String(localized: "Build Artifacts", comment: "Inspector section title: regenerable build output folders"),
                symbol: "shippingbox", content: content, accessory: total)
    }

    private func buildScripts(_ scripts: [ProjectScript]) {
        // One group per file the scripts came from, in detection order.
        var sources: [String] = []
        for script in scripts where !sources.contains(script.source) { sources.append(script.source) }
        let runnerName = scripts.first.map { $0.source == "package.json" ? $0.runner.rawValue : "" } ?? ""
        let content = section()

        let limit = showsAllScripts ? Int.max : Self.collapsedScriptCount
        var shown = 0
        for source in sources {
            let group = scripts.filter { $0.source == source }
            if sources.count > 1, shown < limit {
                let title = source == "package.json" ? "package.json · \(group[0].runner.rawValue)" : source
                add(inset(label(title, size: 10.5, weight: .medium, color: InspectorColors.tertiary), by: ScriptRow.inset), to: content, spacingAfter: 2)
            }
            for script in group where shown < limit {
                let row = ScriptRow(script)
                row.onRun = { [weak self] in self?.run(script) }
                add(row, to: content, spacingAfter: 1)
                shown += 1
            }
            if let last = content.arrangedSubviews.last, sources.count > 1 { content.setCustomSpacing(8, after: last) }
        }
        if scripts.count > shown {
            let more = NSButton(title: String(localized: "Show \(scripts.count - shown) More", comment: "plural"), target: self,
                                action: #selector(showMoreScripts))
            more.isBordered = false
            more.font = .systemFont(ofSize: 11, weight: .medium)
            more.contentTintColor = InspectorColors.accent
            more.attributedTitle = NSAttributedString(string: more.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: InspectorColors.accent,
            ])
            add(inset(more, by: ScriptRow.inset - 1), to: content)
        }
        addCard(id: "scripts", title: String(localized: "Scripts", comment: "Inspector section title: runnable project scripts"),
                symbol: "terminal", content: content,
                accessory: sources.count == 1 && !runnerName.isEmpty ? label(runnerName, size: 11, color: InspectorColors.tertiary) : nil)
    }

    // MARK: - Artifacts state

    /// Opted-in folders that aren't selected by default (virtual environments).
    private var explicitlySelected: Set<String> = []

    private func isSelected(_ artifact: ProjectArtifact) -> Bool {
        artifact.isSelectedByDefault ? !deselected.contains(artifact.id) : explicitlySelected.contains(artifact.id)
    }

    private func toggle(_ artifact: ProjectArtifact, _ on: Bool) {
        if artifact.isSelectedByDefault {
            if on { deselected.remove(artifact.id) } else { deselected.insert(artifact.id) }
        } else {
            if on { explicitlySelected.insert(artifact.id) } else { explicitlySelected.remove(artifact.id) }
        }
        updateArtifacts()
    }

    private var selectedArtifacts: [ProjectArtifact] {
        (info?.artifacts ?? []).filter(isSelected)
    }

    private func updateArtifacts() {
        guard let info else { return }
        for artifact in info.artifacts {
            artifactRows[artifact.id]?.update(artifact, selected: isSelected(artifact))
        }
        let all = info.artifacts
        let known = all.compactMap(\.bytes).saturatingSum
        artifactsTotalLabel?.stringValue = info.isMeasuring
            ? (known > 0 ? String(localized: "\(Format.bytes(known))+", comment: "A total size still being measured: at least this much") : "")
            : Format.bytes(known)
        let chosen = selectedArtifacts
        let chosenBytes = chosen.compactMap(\.bytes).saturatingSum
        let pending = chosen.contains { !$0.isMeasured }
        if let cleanButton {
            cleanButton.title = chosen.isEmpty ? String(localized: "Clean", comment: "Button: move the selected build folders to the Trash")
                : pending ? String(localized: "Clean…", comment: "Button: move the selected build folders to the Trash (asks first)")
                : String(localized: "Clean \(Format.bytes(chosenBytes))…", comment: "Button: move the selected build folders, this size in total, to the Trash (asks first)")
            cleanButton.isEnabled = !chosen.isEmpty
            cleanButton.toolTip = chosen.isEmpty ? String(localized: "Select folders to move to the Trash")
                : String(localized: "Move \(chosen.map(\.name).joined(separator: ", ")) to the Trash", comment: "Tooltip; the placeholder is a list of folder names")
        }
    }

    // MARK: - Actions

    @objc private func cleanClicked() {
        let chosen = selectedArtifacts
        guard !chosen.isEmpty, let info else { return }
        if let onClean { return onClean(chosen) }
        guard let window else { return }
        let folder = info.folder
        ProjectActions.confirmClean(chosen, window: window, files: files) { [weak self, git] urls in
            guard !urls.isEmpty else { return }
            ProjectInfo.invalidateSizes(under: folder)
            FolderSizer.invalidate(folder)
            git.invalidate(containing: folder)
            self?.onDidClean?(urls)
        }
    }

    private func run(_ script: ProjectScript) {
        if let onRunScript { return onRunScript(script) }
        if !ProjectActions.runInTerminal(script, projectName: info?.folder.lastPathComponent) { Sounds.beep() }
    }

    @objc private func showMoreScripts() {
        showsAllScripts = true
        rebuild()
    }

    // MARK: - Helpers

    /// The rows of one card, top to bottom.
    private func section() -> NSStackView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        return content
    }

    private func addCard(id: String, title: String, symbol: String, content: NSStackView, accessory: NSView? = nil) {
        let card = InspectorCard(id: id, title: title, symbol: symbol, content: content, accessory: accessory,
                                 preferences: preferences)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func add(_ view: NSView, to content: NSStackView, spacingAfter spacing: CGFloat = 6) {
        content.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        if !(view is NSButton) || view === cleanButton {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        content.setCustomSpacing(spacing, after: view)
    }

    /// `view` shifted right, to line up with the script names inside their hover background.
    private func inset(_ view: NSView, by amount: CGFloat) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: amount),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

// MARK: - Pieces

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                   monospacedDigits: Bool = false, monospaced: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight)
        : monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

/// Lays out its subviews left to right, wrapping to new lines; height follows the width it's given.
final class FlowView: NSView {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat
    private var lastWidth: CGFloat = 0

    init(spacing: CGFloat, lineSpacing: CGFloat) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func add(_ view: NSView) {
        addSubview(view)
        invalidateIntrinsicContentSize()
    }

    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.intrinsicContentSize
            let w = min(size.width, max(width, 1))
            if x > 0, x + w > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if apply { view.frame = NSRect(x: x, y: y, width: w, height: size.height) }
            x += w + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return y + lineHeight
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrange(width: bounds.width > 0 ? bounds.width : 10_000, apply: false))
    }

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, apply: true)
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A capsule naming one project kind: symbol, name, and the package manager or build system in secondary text.
private final class KindChip: NSView {
    private let symbol: NSImage?
    private let text: NSAttributedString

    init(_ info: ProjectKindInfo) {
        symbol = NSImage(systemSymbolName: info.kind.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [InspectorColors.secondary])))
        let text = NSMutableAttributedString(string: info.kind.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: InspectorColors.primary,
        ])
        if let detail = info.detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: InspectorColors.secondary,
            ]))
        }
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(info.detail.map { "\(info.kind.title), \($0)" } ?? info.kind.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(8 + 14 + 4 + text.size().width + 9), height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        InspectorColors.primary.withAlphaComponent(dark ? 0.10 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if let symbol {
            let s = symbol.size
            symbol.draw(in: NSRect(x: 8 + (14 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let size = text.size()
        text.draw(at: NSPoint(x: 8 + 14 + 4, y: (bounds.height - size.height) / 2))
    }
}

/// Branch name, ahead/behind and an in-progress operation tag (a detached HEAD also gets a symbol).
private final class BranchLine: NSView {
    private let git: ProjectGitSummary

    init(_ git: ProjectGitSummary) {
        self.git = git
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        var parts = [git.branch.isDetached ? String(localized: "Detached at \(git.branch.displayName)", comment: "Git: HEAD is detached at this commit")
                     : String(localized: "Branch \(git.branch.displayName)", comment: "Git: the current branch")]
        if git.branch.ahead > 0 { parts.append(String(localized: "\(git.branch.ahead) ahead", comment: "plural")) }
        if git.branch.behind > 0 { parts.append(String(localized: "\(git.branch.behind) behind", comment: "plural")) }
        if let operation = git.operation { parts.append(operation.title) }
        setAccessibilityLabel(parts.joined(separator: ", "))
        toolTip = git.branch.oid.map { "HEAD \(String($0.prefix(12)))" }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        // The card's header already shows the branch symbol; a detached HEAD gets its own.
        let symbol = git.branch.isDetached ? NSImage(systemSymbolName: "smallcircle.filled.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium).applying(.init(paletteColors: [InspectorColors.secondary]))) : nil
        var x: CGFloat = 0
        if let symbol {
            let s = symbol.size
            symbol.draw(in: NSRect(x: (16 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x = 22
        }
        var trailing: [NSAttributedString] = []
        var counts: [String] = []
        if git.branch.ahead > 0 { counts.append("↑\(git.branch.ahead)") }
        if git.branch.behind > 0 { counts.append("↓\(git.branch.behind)") }
        if !counts.isEmpty {
            trailing.append(NSAttributedString(string: counts.joined(separator: " "), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: InspectorColors.secondary,
            ]))
        }
        if let operation = git.operation {
            trailing.append(NSAttributedString(string: operation.title.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: InspectorColors.conflict, .kern: 0.4,
            ]))
        }
        let trailingWidth = trailing.reduce(0) { $0 + ceil($1.size().width) + 8 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let font = git.branch.isDetached ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
            : NSFont.systemFont(ofSize: 13, weight: .semibold)
        let name = NSAttributedString(string: git.branch.displayName, attributes: [
            .font: font, .foregroundColor: InspectorColors.primary, .paragraphStyle: paragraph,
        ])
        let nameSize = name.size()
        let nameWidth = min(ceil(nameSize.width), bounds.width - x - trailingWidth)
        name.draw(with: NSRect(x: x, y: (bounds.height - nameSize.height) / 2, width: nameWidth, height: nameSize.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        x += nameWidth + 8
        for item in trailing {
            let s = item.size()
            item.draw(at: NSPoint(x: x, y: (bounds.height - s.height) / 2))
            x += ceil(s.width) + 8
        }
    }
}

/// "● 3 modified": a colored dot (or a small symbol) and a count.
final class StatusItem: NSView {
    private let dot: NSColor?
    private let symbol: NSImage?
    let text: NSAttributedString

    init(_ dot: NSColor?, _ title: String, color: NSColor = InspectorColors.secondary) {
        self.dot = dot
        symbol = nil
        text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: color])
        super.init(frame: .zero)
        configureAccessibility(title)
    }

    init(symbol name: String, _ title: String) {
        dot = nil
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .medium).applying(.init(paletteColors: [InspectorColors.secondary])))
        text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: InspectorColors.secondary,
        ])
        super.init(frame: .zero)
        configureAccessibility(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureAccessibility(_ title: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    override var isFlipped: Bool { true }

    private var leading: CGFloat { dot != nil || symbol != nil ? 12 : 0 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(leading + text.size().width), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.height / 2
        if let dot {
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: midY - 3, width: 6, height: 6)).fill()
        } else if let symbol {
            let s = symbol.size
            symbol.draw(in: NSRect(x: (8 - s.width) / 2, y: midY - s.height / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let size = text.size()
        text.draw(at: NSPoint(x: leading, y: midY - size.height / 2))
    }
}

/// Checkbox, folder icon, name (plus "environment" for virtual envs) and size.
private final class ArtifactRow: NSView {
    var onToggle: ((Bool) -> Void)?
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let nameLabel: NSTextField
    private let sizeLabel = label("", size: 11, color: InspectorColors.secondary, monospacedDigits: true)
    private let spinner = NSProgressIndicator()

    init(_ artifact: ProjectArtifact, selected: Bool) {
        let name = NSMutableAttributedString(string: artifact.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: InspectorColors.primary,
        ])
        if artifact.urls.count > 1 {
            name.append(NSAttributedString(string: "  ×\(artifact.urls.count)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: InspectorColors.tertiary,
            ]))
        }
        if artifact.role == .environment {
            name.append(NSAttributedString(string: "  " + String(localized: "environment", comment: "Note after a build folder's name: it's a virtual environment"), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: InspectorColors.tertiary,
            ]))
        }
        nameLabel = NSTextField(labelWithAttributedString: name)
        super.init(frame: .zero)

        checkbox.controlSize = .small
        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.setAccessibilityLabel(artifact.name)
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: .folder))
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.alignment = .right
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        toolTip = artifact.urls.map { Format.tildePath($0) }.joined(separator: "\n")

        for view in [checkbox, icon, nameLabel, sizeLabel, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(artifact, selected: selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ artifact: ProjectArtifact, selected: Bool) {
        checkbox.state = selected ? .on : .off
        if let bytes = artifact.bytes {
            sizeLabel.stringValue = Format.bytes(bytes)
            spinner.stopAnimation(nil)
        } else {
            sizeLabel.stringValue = ""
            spinner.startAnimation(nil)
        }
        let size = artifact.bytes.map(Format.bytes)
            ?? String(localized: "measuring", comment: "Accessibility: the folder's size is still being measured")
        setAccessibilityLabel("\(artifact.name), \(size)")
    }

    @objc private func toggled() {
        onToggle?(checkbox.state == .on)
    }
}

/// Script name over its command (monospaced, secondary), with a play button that runs it in a terminal.
private final class ScriptRow: NSView {
    /// Text inset inside the row's hover background.
    static let inset: CGFloat = 6
    var onRun: (() -> Void)?
    private let script: ProjectScript
    private let runButton = NSButton()
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(_ script: ProjectScript) {
        self.script = script
        super.init(frame: .zero)
        let name = label(script.name, size: 12, weight: .medium, color: InspectorColors.primary)
        // Prose (## help, doc comments) in the text font; commands monospaced.
        let command = script.summary.map { label($0, size: 11, color: InspectorColors.secondary) }
            ?? label(script.command.isEmpty ? script.invocation : script.command, size: 10.5, color: InspectorColors.secondary,
                     monospaced: true)
        command.lineBreakMode = .byTruncatingTail
        runButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: String(localized: "Run \(script.name) in Terminal"))
        runButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        runButton.isBordered = false
        runButton.imagePosition = .imageOnly
        runButton.contentTintColor = InspectorColors.secondary
        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.toolTip = String(localized: "Run “\(script.invocation)” in Terminal", comment: "Tooltip; the placeholder is a shell command")
        toolTip = ([script.invocation] + [script.summary, script.command.isEmpty ? nil : script.command].compactMap { $0 })
            .joined(separator: "\n")

        for view in [name, command, runButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            name.trailingAnchor.constraint(lessThanOrEqualTo: runButton.leadingAnchor, constant: -6),
            command.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            command.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 0),
            command.trailingAnchor.constraint(lessThanOrEqualTo: runButton.leadingAnchor, constant: -6),
            runButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            runButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            runButton.widthAnchor.constraint(equalToConstant: 22),
            runButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(script.name): \(script.summary ?? script.command)")
        menu = makeMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        InspectorColors.primary.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hovering = on
        runButton.contentTintColor = on ? InspectorColors.accent : InspectorColors.secondary
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRun?() }
    }

    @objc private func runClicked() { onRun?() }

    override func accessibilityPerformPress() -> Bool {
        onRun?()
        return true
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let run = NSMenuItem(title: String(localized: "Run in Terminal"), action: #selector(runClicked), keyEquivalent: "")
        run.target = self
        run.image = NSImage(systemSymbolName: "play", accessibilityDescription: nil)
        menu.addItem(run)
        let copy = NSMenuItem(title: String(localized: "Copy Command", comment: "Menu command: copy the script's shell command"), action: #selector(copyCommand), keyEquivalent: "")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copy)
        return menu
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script.invocation, forType: .string)
    }
}

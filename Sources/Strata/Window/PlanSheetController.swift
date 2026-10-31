import AppKit

/// "Ask Strata…": describe a change for the selected files, review the plan, apply it as one undoable step.
///
/// The sheet goes through: prompt (instruction field + suggestions) → planning (spinner) → review (checkbox table of
/// before → after, skipped steps with reasons, summary line) → applying. Apply runs `PlanExecutor` with the window's undo manager.
final class PlanSheetController: NSViewController {
    enum Phase {
        case prompt
        case planning
        case review(Plan)
        case failed(String, suggestions: [String])
        case applying(Plan)
    }

    var phase: Phase = .prompt {
        didSet { render() }
    }

    private let urls: [URL]
    /// Each step's places as `PlanValidator.key` spells them, worked out with the plan: checking and unchecking
    /// steps compares them across the whole plan.
    /// What the steps' places are on disk, read once the plan arrives: their keys (as their disks compare names),
    /// whether each destination is taken, and whether by the step's own item.
    private var facts = Facts()
    private let baseFolder: URL
    private let files: FileCommands
    private weak var undoManagerForApply: UndoManager?
    private var items: [PlanItem] = []
    private var completion: ((PlanExecutor.Outcome?) -> Void)?
    private var planTask: Task<Void, Never>?
    private var rows: [PlanStep] = []

    private let badge = BadgeView()
    private let subtitle = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let planButton = NSButton()
    private let understood = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let well = WellView()
    private let overlay = NSStackView()
    private let summary = NSTextField(labelWithString: "")
    private let footerSpinner = NSProgressIndicator()
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private let applyButton = NSButton(title: String(localized: "Apply", comment: "Button: apply the plan’s changes"), target: nil, action: nil)

    static let size = NSSize(width: 680, height: 540)

    init(urls: [URL], baseFolder: URL, undoManager: UndoManager?, files: FileCommands) {
        self.urls = urls
        self.baseFolder = baseFolder
        self.files = files
        undoManagerForApply = undoManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Presenting

    /// Shows the sheet on `window` for the selection. `instruction`, when given, is planned right away.
    @discardableResult
    static func present(on window: NSWindow, urls: [URL], baseFolder: URL, undoManager: UndoManager?, instruction: String? = nil,
                        files: FileCommands,
                        completion: @escaping (PlanExecutor.Outcome?) -> Void) -> PlanSheetController {
        let controller = PlanSheetController(urls: urls, baseFolder: baseFolder, undoManager: undoManager, files: files)
        controller.completion = completion
        let sheet = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: true)
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.minSize = NSSize(width: 560, height: 420)
        sheet.contentViewController = controller
        sheet.setContentSize(size)
        ThemeStyle.bind(sheet)
        window.beginSheet(sheet)
        controller.start(instruction: instruction)
        return controller
    }

    /// Loads the selection's metadata, then plans `instruction` if given.
    func start(instruction: String?) {
        Task {
            items = await PlanItem.load(urls)
            subtitle.stringValue = String(localized: "\(items.count) items in “\(FileManager.default.displayName(atPath: baseFolder.path))”", comment: "plural")
            render()
            if let instruction, !instruction.isEmpty {
                field.stringValue = instruction
                generate(nil)
            }
        }
    }

    /// For previews and tests: show a phase with known items.
    func show(_ phase: Phase, items: [PlanItem], instruction: String) {
        _ = view
        self.items = items
        field.stringValue = instruction
        subtitle.stringValue = String(localized: "\(items.count) items in “\(baseFolder.lastPathComponent)”", comment: "plural")
        self.phase = phase
    }

    // MARK: - Layout

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        ThemeStyle.bind(root, to: .content)
        let header = makeHeader()
        let ask = makeRequestRow()
        configureUnderstood()
        configureWell()
        let footer = makeFooter()
        layOut(header: header, ask: ask, footer: footer, in: root)
        view = root
        ThemeStyle.refresh(root)
        render()
    }

    /// Strata's icon, the title and the selection, and the badge saying how the plan was made.
    private func makeHeader() -> NSStackView {
        let icon = AppIconBadge()
        let title = NSTextField(labelWithString: String(localized: "Ask Strata", comment: "Title of the sheet where you describe a change for the selected files"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let header = NSStackView(views: [icon, titles, NSView(), badge])
        header.alignment = .centerY
        header.spacing = 10
        return header
    }

    /// Where you describe the change, and Plan.
    private func makeRequestRow() -> NSStackView {
        field.placeholderString = String(localized: "Describe what to do — e.g. “rename these photos by date taken”")
        field.font = .systemFont(ofSize: 14)
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.target = self
        field.action = #selector(generate(_:))
        field.delegate = self
        planButton.title = String(localized: "Plan", comment: "Button: make a plan for the described change")
        planButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        planButton.imagePosition = .imageLeading
        planButton.bezelStyle = .push
        planButton.controlSize = .large
        planButton.target = self
        planButton.action = #selector(generate(_:))
        let ask = NSStackView(views: [field, planButton])
        ask.spacing = 8
        ask.alignment = .centerY
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return ask
    }

    /// What the request was understood to mean, under it.
    private func configureUnderstood() {
        understood.font = .systemFont(ofSize: 11.5)
        understood.textColor = .secondaryLabelColor
        understood.lineBreakMode = .byTruncatingTail
        understood.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// The planned steps, with an overlay for what's happening when there are none to show.
    private func configureWell() {
        let column = NSTableColumn(identifier: .init("step"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(scroll)
        overlay.orientation = .vertical
        overlay.alignment = .centerX
        overlay.spacing = 10
        overlay.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(overlay)
    }

    /// Progress, the summary, Cancel and Apply.
    private func makeFooter() -> NSStackView {
        summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerSpinner.style = .spinning
        footerSpinner.controlSize = .small
        footerSpinner.isDisplayedWhenStopped = false
        cancelButton.bezelStyle = .push
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        applyButton.bezelStyle = .push
        applyButton.controlSize = .large
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        let footer = NSStackView(views: [footerSpinner, summary, NSView(), cancelButton, applyButton])
        footer.alignment = .centerY
        footer.spacing = 8
        footer.setCustomSpacing(12, after: summary)
        return footer
    }

    private func layOut(header: NSStackView, ask: NSStackView, footer: NSStackView, in root: NSView) {
        let stack = NSStackView(views: [header, ask, understood, well, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: header)
        stack.setCustomSpacing(7, after: ask)
        stack.setCustomSpacing(10, after: understood)
        stack.setCustomSpacing(16, after: well)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for view in [header, ask, well, footer, understood] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            well.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: well.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: well.widthAnchor, constant: -60),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        well.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if case .prompt = phase { view.window?.makeFirstResponder(field) }
    }

    // MARK: - States

    private func render() {
        guard isViewLoaded else { return }
        overlay.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footerSpinner.stopAnimation(nil)
        footerSpinner.isHidden = true
        summary.textColor = .secondaryLabelColor
        field.isEnabled = true
        planButton.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        cancelButton.isEnabled = true
        understood.isHidden = true

        switch phase {
        case .prompt:
            rows = []
            badge.set(nil)
            summary.stringValue = AIModel.isAvailable ? String(localized: "Plans are made on this Mac and shown before anything changes.")
                : AIModel.isSupported ? String(localized: "\(AIModel.shortStatus) — Strata’s built-in rules handle common requests.",
                                               comment: "Starts with why Apple Intelligence can’t be used, like “Apple Intelligence is off”")
                : String(localized: "Strata’s built-in rules make the plan, and it’s shown before anything changes.")
            showSuggestions(PlanGenerator.suggestions(for: items), title: items.isEmpty ? nil : String(localized: "Try one of these"))
            applyButton.title = String(localized: "Apply", comment: "Button: apply the plan’s changes")
            applyButton.isEnabled = false
        case .planning:
            rows = []
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .regular
            spinner.startAnimation(nil)
            overlay.addArrangedSubview(spinner)
            overlay.addArrangedSubview(label(AIModel.isAvailable ? String(localized: "Planning with Apple Intelligence…") : String(localized: "Planning…"),
                                             size: 12.5, color: .secondaryLabelColor))
            summary.stringValue = ""
            planButton.isEnabled = false
            applyButton.isEnabled = false
        case let .review(plan):
            rows = plan.steps + plan.excluded
            badge.set(plan.source)
            understood.isHidden = false
            understood.attributedStringValue = interpretation(plan)
            if rows.isEmpty {
                overlay.addArrangedSubview(symbol("checkmark.circle", size: 26, color: .tertiaryLabelColor))
                overlay.addArrangedSubview(label(String(localized: "Nothing to change — everything already matches."), size: 12.5, color: .secondaryLabelColor))
            }
            updateFooter(plan)
        case let .failed(message, suggestions):
            rows = []
            badge.set(nil)
            overlay.addArrangedSubview(symbol("questionmark.bubble", size: 26, color: .tertiaryLabelColor))
            let text = label(message, size: 12.5, color: .secondaryLabelColor)
            text.alignment = .center
            overlay.addArrangedSubview(text)
            if AIModel.canOpenSettings {
                let settings = NSButton(title: String(localized: "Open Apple Intelligence Settings…"), target: self, action: #selector(openSettings(_:)))
                settings.bezelStyle = .push
                settings.controlSize = .small
                overlay.addArrangedSubview(settings)
            }
            if !suggestions.isEmpty {
                if let last = overlay.arrangedSubviews.last { overlay.setCustomSpacing(18, after: last) }
                appendSuggestions(suggestions, title: String(localized: "Strata can do these without it", comment: "Heading of requests Strata can plan without Apple Intelligence"))
            }
            summary.stringValue = ""
            applyButton.title = String(localized: "Apply", comment: "Button: apply the plan’s changes")
            applyButton.isEnabled = false
        case let .applying(plan):
            rows = plan.steps + plan.excluded
            footerSpinner.isHidden = false
            footerSpinner.startAnimation(nil)
            summary.stringValue = String(localized: "Applying…")
            field.isEnabled = false
            planButton.isEnabled = false
            applyButton.isEnabled = false
            cancelButton.isEnabled = false
        }
        table.reloadData()
        scroll.isHidden = rows.isEmpty
    }

    private func updateFooter(_ plan: Plan) {
        var text = plan.summary
        if plan.unaffected > 0 { text += " · " + String(localized: "\(plan.unaffected) unchanged", comment: "plural; how many selected items a plan leaves as they are") }
        summary.stringValue = text
        let count = plan.changeCount
        // A new plan after a partly failed one: the button applies again (it had become "Done").
        applyButton.action = #selector(apply(_:))
        summary.textColor = .secondaryLabelColor
        applyButton.title = count == 0 ? String(localized: "Apply", comment: "Button: apply the plan’s changes")
            : String(localized: "Apply \(count) Changes", comment: "plural")
        applyButton.isEnabled = count > 0
    }

    private func interpretation(_ plan: Plan) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let check = NSTextAttachment()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold).applying(.init(paletteColors: [.white, .systemGreen])))
        text.append(NSAttributedString(attachment: check))
        let sentence = "  " + String(localized: "Understood as \(plan.interpretation)",
                                     comment: "Ask Strata: what the request was read as, like “Understood as Rename by date taken”")
        let line = NSMutableAttributedString(string: sentence, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                            .font: NSFont.systemFont(ofSize: 11.5)])
        let range = (sentence as NSString).range(of: plan.interpretation, options: .backwards)
        if range.location != NSNotFound, !plan.interpretation.isEmpty {
            line.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11.5, weight: .medium)], range: range)
        }
        text.append(line)
        return text
    }

    private func showSuggestions(_ suggestions: [String], title: String?) {
        guard !suggestions.isEmpty else {
            overlay.addArrangedSubview(symbol("sparkles", size: 26, color: .tertiaryLabelColor))
            overlay.addArrangedSubview(label(String(localized: "Describe a rename, move, grouping or clean-up."), size: 12.5, color: .secondaryLabelColor))
            return
        }
        appendSuggestions(suggestions, title: title)
    }

    private func appendSuggestions(_ suggestions: [String], title: String?) {
        if let title {
            let heading = label(title.uppercased(), size: 10.5, color: .tertiaryLabelColor, weight: .semibold)
            overlay.addArrangedSubview(heading)
            overlay.setCustomSpacing(8, after: heading)
        }
        for suggestion in suggestions {
            let button = SuggestionButton(title: suggestion, target: self, action: #selector(useSuggestion(_:)))
            overlay.addArrangedSubview(button)
        }
    }

    private func label(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.preferredMaxLayoutWidth = 420
        return label
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: size, weight: .light)
        view.contentTintColor = color
        return view
    }

    // MARK: - Actions

    @objc private func generate(_ sender: Any?) {
        let instruction = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        if case .applying = phase { return }
        planTask?.cancel()
        phase = .planning
        let request = PlanGenerator.Request(instruction: instruction, items: items, baseFolder: baseFolder)
        planTask = Task { [weak self] in
            do {
                let plan = try await PlanGenerator.generate(request)
                guard await self?.review(plan) == true else { return }
                self?.view.window?.makeFirstResponder(self?.table)
            } catch {
                guard !Task.isCancelled else { return }
                var suggestions: [String] = []
                if case let .notUnderstood(list) = error as? PlanError { suggestions = list }
                self?.phase = .failed(error.localizedDescription, suggestions: suggestions)
            }
        }
    }

    @objc private func useSuggestion(_ sender: NSButton) {
        field.stringValue = sender.title
        generate(nil)
    }

    @objc private func openSettings(_ sender: Any?) {
        AIModel.openSettings()
    }

    @objc private func cancel(_ sender: Any?) {
        planTask?.cancel()
        finish(nil)
    }

    @objc private func apply(_ sender: Any?) {
        guard case let .review(plan) = phase, plan.changeCount > 0 else { return }
        phase = .applying(plan)
        Task {
            let outcome = await files.apply(plan, actionName: PlanExecutor.actionName(for: plan), undo: undoManagerForApply)
            if outcome.failures.isEmpty {
                finish(outcome)
            } else {
                // Keep the sheet up to explain; what did apply can be undone with ⌘Z.
                phase = .review(plan)
                summary.stringValue = String(localized: "\(outcome.failures.count) changes failed: \(outcome.failures[0])", comment: "plural")
                summary.textColor = .systemRed
                applyButton.title = String(localized: "button.done", defaultValue: "Done", comment: "Button that closes the sheet once the plan is applied")
                applyButton.action = #selector(done(_:))
                applyButton.isEnabled = true
                pendingOutcome = outcome
            }
        }
    }

    private var pendingOutcome: PlanExecutor.Outcome?

    @objc private func done(_ sender: Any?) {
        finish(pendingOutcome)
    }

    private func finish(_ outcome: PlanExecutor.Outcome?) {
        if let sheet = view.window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
        completion?(outcome)
        completion = nil
    }

    /// Shows `plan` for review once what its steps' places are has been read (toggling decides from that); false
    /// when the request was replaced or cancelled meanwhile.
    func review(_ plan: Plan) async -> Bool {
        let facts = await Self.facts(of: plan)
        guard !Task.isCancelled else { return false }
        self.facts = facts
        phase = .review(plan)
        return true
    }

    nonisolated struct Facts: Sendable {
        var keys: [URL: String] = [:]
        /// Destinations something is at.
        var taken: Set<URL> = []
        /// Steps whose destination is their own item (a case-only rename).
        var ownPlace: Set<Int> = []

        /// Every source, destination and destination's folder has a key; anything else is compared as spelled.
        func key(_ url: URL) -> String { keys[url] ?? url.standardizedFileURL.path }
        /// Whether `step`'s destination is taken by something other than its own item.
        func occupied(_ step: PlanStep) -> Bool {
            step.destination.map { taken.contains($0) && !ownPlace.contains(step.id) } ?? false
        }
    }

    @concurrent private static func facts(of plan: Plan) async -> Facts {
        let places = plan.steps.flatMap { [$0.source, $0.destination, $0.destination?.deletingLastPathComponent()] }
        var facts = Facts()
        facts.keys = Dictionary(places.compactMap { $0 }.map { ($0, PlanValidator.key($0)) }, uniquingKeysWith: { first, _ in first })
        for step in plan.steps {
            guard let destination = step.destination, TransferEngine.exists(destination) else { continue }
            facts.taken.insert(destination)
            if let source = step.source, PlanValidator.sameItem(destination, source) { facts.ownPlace.insert(step.id) }
        }
        return facts
    }

    func toggle(_ id: Int, on: Bool) {
        guard case var .review(plan) = phase, let index = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        let facts = facts
        func placeKey(_ url: URL) -> String { facts.key(url) }
        plan.steps[index].isEnabled = on
        if !on {
            // Unchecking a step that vacates a name disables any step that would otherwise land on that existing file.
            var unvacated = plan.steps[index].source.map { [placeKey($0)] } ?? []
            while let key = unvacated.popLast() {
                for i in plan.steps.indices where plan.steps[i].isEnabled {
                    guard let dest = plan.steps[i].destination, placeKey(dest) == key, facts.occupied(plan.steps[i]) else { continue }
                    plan.steps[i].isEnabled = false
                    if let source = plan.steps[i].source { unvacated.append(placeKey(source)) }
                }
            }
        } else {
            // Re-enabling a step whose destination is occupied by another planned item re-enables the step that vacates it.
            var needed: [String] = plan.steps[index].destination.flatMap { dest in
                facts.occupied(plan.steps[index]) ? [placeKey(dest)] : nil
            } ?? []
            while let key = needed.popLast() {
                for i in plan.steps.indices where !plan.steps[i].isEnabled && plan.steps[i].problem == nil {
                    guard let source = plan.steps[i].source, placeKey(source) == key else { continue }
                    plan.steps[i].isEnabled = true
                    if let dest = plan.steps[i].destination, facts.occupied(plan.steps[i]) {
                        needed.append(placeKey(dest))
                    }
                }
            }
        }
        // New folders follow the moves that need them.
        for (i, step) in plan.steps.enumerated() where step.kind == .createFolder {
            let folder = step.destination.map(placeKey) ?? ""
            plan.steps[i].isEnabled = plan.steps.contains { other in
                other.isEnabled && other.kind == .move && (other.destination.map { placeKey($0.deletingLastPathComponent()) }.map {
                    $0 == folder || $0.hasPrefix(folder + "/")
                } ?? false)
            }
        }
        phase = .review(plan)
    }
}

extension PlanSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        planButton.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension PlanSheetController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("PlanRow")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PlanRowView ?? {
            let cell = PlanRowView()
            cell.identifier = id
            return cell
        }()
        let step = rows[row]
        var editable = true
        if case .applying = phase { editable = false }
        cell.configure(step, base: baseFolder, editable: editable && step.problem == nil && step.kind != .createFolder) { [weak self] on in
            self?.toggle(step.id, on: on)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = PlanTableRow()
        rowView.isLast = row == rows.count - 1
        return rowView
    }
}

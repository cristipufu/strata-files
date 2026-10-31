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
    private var keys: [URL: String] = [:]
    private let baseFolder: URL
    private let files: BrowserFileCommands
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

    init(urls: [URL], baseFolder: URL, undoManager: UndoManager?, files: BrowserFileCommands) {
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
                        files: BrowserFileCommands,
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

        understood.font = .systemFont(ofSize: 11.5)
        understood.textColor = .secondaryLabelColor
        understood.lineBreakMode = .byTruncatingTail
        understood.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        view = root
        ThemeStyle.refresh(root)
        render()
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
                let keys = await Self.keys(of: plan)
                guard !Task.isCancelled else { return }
                self?.keys = keys
                self?.phase = .review(plan)
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

    @concurrent private static func keys(of plan: Plan) async -> [URL: String] {
        let places = plan.steps.flatMap { [$0.source, $0.destination, $0.destination?.deletingLastPathComponent()] }
        return Dictionary(places.compactMap { $0 }.map { ($0, PlanValidator.key($0)) }, uniquingKeysWith: { first, _ in first })
    }

    func toggle(_ id: Int, on: Bool) {
        guard case var .review(plan) = phase, let index = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        let keys = keys
        func placeKey(_ url: URL) -> String { keys[url] ?? PlanValidator.key(url) }
        plan.steps[index].isEnabled = on
        if !on {
            // Unchecking a step that vacates a name disables any step that would otherwise land on that existing file.
            var unvacated = plan.steps[index].source.map { [placeKey($0)] } ?? []
            while let key = unvacated.popLast() {
                for i in plan.steps.indices where plan.steps[i].isEnabled {
                    guard let dest = plan.steps[i].destination, placeKey(dest) == key,
                          TransferEngine.exists(dest),
                          plan.steps[i].source.map({ !PlanValidator.sameItem(dest, $0) }) ?? true else { continue }
                    plan.steps[i].isEnabled = false
                    if let source = plan.steps[i].source { unvacated.append(placeKey(source)) }
                }
            }
        } else {
            // Re-enabling a step whose destination is occupied by another planned item re-enables the step that vacates it.
            var needed: [String] = plan.steps[index].destination.flatMap { dest in
                let same = plan.steps[index].source.map { PlanValidator.sameItem(dest, $0) } ?? false
                return TransferEngine.exists(dest) && !same ? [placeKey(dest)] : nil
            } ?? []
            while let key = needed.popLast() {
                for i in plan.steps.indices where !plan.steps[i].isEnabled && plan.steps[i].problem == nil {
                    guard let source = plan.steps[i].source, placeKey(source) == key else { continue }
                    plan.steps[i].isEnabled = true
                    if let dest = plan.steps[i].destination, TransferEngine.exists(dest), !PlanValidator.sameItem(dest, source) {
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

// MARK: - Views

/// One step: [checkbox] [icon] before → after, aligned in two columns.
final class PlanRowView: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let before = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    private let after = NSTextField(labelWithString: "")
    private var onToggle: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        checkbox.target = self
        checkbox.action = #selector(toggled(_:))
        checkbox.controlSize = .small
        icon.imageScaling = .scaleProportionallyDown
        for label in [before, after] {
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: String(localized: "becomes", comment: "VoiceOver: an old name becomes a new one"))
        arrow.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        arrow.contentTintColor = .tertiaryLabelColor
        for view in [checkbox, icon, before, arrow, after] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled(_ sender: NSButton) {
        onToggle?(sender.state == .on)
    }

    func configure(_ step: PlanStep, base: URL, editable: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        defer {
            for label in [before, after] {
                let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
                text.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: text.length))
                label.attributedStringValue = text
            }
        }
        let excluded = step.problem != nil
        checkbox.state = step.isEnabled && !excluded ? .on : .off
        checkbox.isEnabled = editable
        // New folders follow their moves, and skipped steps can't be applied: no checkbox to suggest otherwise.
        checkbox.isHidden = excluded || step.kind == .createFolder
        arrow.isHidden = false

        let symbolName: String
        let tint: NSColor
        switch (excluded, step.kind) {
        case (true, _): (symbolName, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        case (false, .rename): (symbolName, tint) = ("pencil", .controlAccentColor)
        case (false, .move): (symbolName, tint) = ("arrow.turn.down.right", .controlAccentColor)
        case (false, .createFolder): (symbolName, tint) = ("folder.badge.plus", .systemGreen)
        case (false, .trash): (symbolName, tint) = ("trash", .systemRed)
        }
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: step.kind.title)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = tint
        icon.alphaValue = step.isEnabled || excluded ? 1 : 0.45

        let dim = !step.isEnabled && !excluded
        let primary: NSColor = dim ? .tertiaryLabelColor : .labelColor
        let secondary: NSColor = dim ? .tertiaryLabelColor : .secondaryLabelColor

        switch step.kind {
        case .createFolder:
            let path = step.destination.map { relative($0, to: base) } ?? ""
            before.attributedStringValue = NSAttributedString(string: path, attributes: [.font: font.withWeight(.medium), .foregroundColor: primary])
            after.attributedStringValue = NSAttributedString(string: String(localized: "New folder", comment: "Plan step: a folder the plan creates"),
                                                             attributes: [.font: font, .foregroundColor: secondary])
        default:
            before.attributedStringValue = NSAttributedString(string: step.beforeName, attributes: [
                .font: font, .foregroundColor: excluded ? NSColor.secondaryLabelColor : secondary,
            ])
            if let problem = step.problem {
                after.attributedStringValue = NSAttributedString(string: problem, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange,
                ])
            } else if step.kind == .trash {
                after.attributedStringValue = NSAttributedString(string: String(localized: "Trash", comment: "Plan step: where an item goes (the Trash)"),
                                                                 attributes: [.font: font.withWeight(.medium), .foregroundColor: dim ? secondary : NSColor.systemRed])
            } else if step.kind == .move, let destination = step.destination {
                let folder = relative(destination.deletingLastPathComponent(), to: base)
                let text = NSMutableAttributedString(string: folder + "/", attributes: [.font: font.withWeight(.semibold), .foregroundColor: dim ? secondary : NSColor.controlAccentColor])
                text.append(NSAttributedString(string: destination.lastPathComponent, attributes: [.font: font, .foregroundColor: primary]))
                after.attributedStringValue = text
            } else if let destination = step.destination {
                after.attributedStringValue = highlighted(old: step.beforeName, new: destination.lastPathComponent, font: font, color: primary, accent: dim ? secondary : .controlAccentColor)
            }
        }
        var tip = [step.source?.path, step.destination.map { "→ " + $0.path }].compactMap { $0 }.joined(separator: "\n")
        if let note = step.note { tip += "\n" + note }
        if let problem = step.problem { tip += "\n" + problem }
        toolTip = tip
        setAccessibilityLabel(step.kind == .trash
                              ? String(localized: "\(step.kind.title): \(before.stringValue)", comment: "VoiceOver: a plan step (like “Move to Trash”), then an item’s name")
                              : String(localized: "\(step.kind.title): \(before.stringValue) to \(after.stringValue)",
                                       comment: "VoiceOver: a plan step (like “Rename”), an item’s name, then what it becomes"))
        needsLayout = true
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    /// The part of the new name that differs, in the accent colour (whole words: "IMG_0412" → "2024-05-12 14.03.22", not "…2").
    private func highlighted(old: String, new: String, font: NSFont, color: NSColor, accent: NSColor) -> NSAttributedString {
        let a = Array(old), b = Array(new)
        func isSeparator(_ c: Character) -> Bool { c == " " || c == "." || c == "-" || c == "_" || c == "(" || c == ")" }
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        // A shared prefix only counts up to the end of a word.
        while prefix > 0, prefix < b.count, !isSeparator(b[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // A shared suffix must start at a separator (".JPG", " copy").
        while suffix > 0, !isSeparator(b[b.count - suffix]) { suffix -= 1 }
        let text = NSMutableAttributedString(string: new, attributes: [.font: font, .foregroundColor: color])
        let changed = b.count - prefix - suffix
        if changed > 0 {
            let start = String(b[..<prefix]).utf16.count
            let length = String(b[prefix..<(prefix + changed)]).utf16.count
            text.addAttributes([.foregroundColor: accent, .font: font.withWeight(.semibold)], range: NSRange(location: start, length: length))
        }
        return text
    }

    private func relative(_ url: URL, to base: URL) -> String {
        let path = url.standardizedFileURL.path, root = base.standardizedFileURL.path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        checkbox.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        icon.frame = NSRect(x: 36, y: (h - 16) / 2, width: 18, height: 16)
        let start: CGFloat = 62
        let column = ((bounds.width - start - 14) * 0.46).rounded()
        let labelHeight: CGFloat = 17
        before.frame = NSRect(x: start, y: (h - labelHeight) / 2, width: column - 8, height: labelHeight)
        arrow.frame = NSRect(x: start + column, y: (h - 12) / 2, width: 14, height: 12)
        after.frame = NSRect(x: start + column + 24, y: (h - labelHeight) / 2, width: bounds.width - start - column - 24 - 14, height: labelHeight)
    }
}

/// Hairline separators between rows, inset like System Settings lists.
private final class PlanTableRow: NSTableRowView {
    var isLast = false

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isLast else { return }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 62, y: bounds.maxY - 0.5, width: bounds.width - 62, height: 0.5).fill()
    }
}

/// The table's rounded, recessed background.
final class WellView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ThemeStyle.surface(.content).cgColor
            layer?.borderColor = ThemeStyle.border.cgColor
        }
        layer?.borderWidth = 0.5
    }
}

/// "Built-in rules" / "✦ Apple Intelligence" capsule.
final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ source: Plan.Source?) {
        isHidden = source == nil
        guard let source else { return }
        let text = NSMutableAttributedString()
        if source == .model {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: source.title))
        text.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11, weight: .medium)],
                           range: NSRange(location: 0, length: text.length))
        label.attributedStringValue = text
        toolTip = source == .model ? String(localized: "Planned on this Mac with Apple Intelligence")
            : String(localized: "Planned by Strata’s built-in rules — no AI involved")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// The sheet's sparkles mark: an accent-filled rounded square.
private final class AppIconBadge: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        let image = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let gradient = layer?.sublayers?.first(where: { $0.name == "gradient" }) as? CAGradientLayer ?? {
                let g = CAGradientLayer()
                g.name = "gradient"
                g.cornerRadius = 8
                g.cornerCurve = .continuous
                layer?.insertSublayer(g, at: 0)
                return g
            }()
            gradient.frame = bounds
            let accent = NSColor.controlAccentColor
            gradient.colors = [
                (accent.blended(withFraction: 0.25, of: .white) ?? accent).cgColor,
                (accent.blended(withFraction: 0.15, of: .black) ?? accent).cgColor,
            ]
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        layer?.sublayers?.first(where: { $0.name == "gradient" })?.frame = bounds
    }
}

/// A suggestion as a quiet capsule button.
private final class SuggestionButton: NSButton {
    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        imagePosition = .imageLeading
        bezelStyle = .push
        controlSize = .regular
        font = .systemFont(ofSize: 12.5)
        contentTintColor = .controlAccentColor
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        .monospacedDigitSystemFont(ofSize: pointSize, weight: weight)
    }
}

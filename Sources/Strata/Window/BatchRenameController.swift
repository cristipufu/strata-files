import AppKit

/// Rename N Items…: a rule (replace, add, format or change case) previewed live for every selected item, with the
/// same checks and the same single undo step as Ask Strata.
final class BatchRenameController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let urls: [URL]
    private let baseFolder: URL
    private weak var undo: UndoManager?
    private let copies: CopyProviders
    private let history: OperationLog
    private var items: [PlanItem] = []
    private var rules = RenameRules()
    private var plan: Plan?
    private var rows: [PlanStep] = []
    /// The preview being worked out (off the main thread, once typing pauses); older ones are dropped.
    private var previewTask: Task<Void, Never>?
    /// Renaming: the sheet doesn't change (or close) until it's done.
    private var isApplying = false
    /// What was renamed, to select it afterwards.
    var onApplied: (([URL]) -> Void)?

    private let mode = NSPopUpButton()
    private let find = NSTextField()
    private let replacement = NSTextField()
    private let regex = NSButton(checkboxWithTitle: String(localized: "Regular expression"), target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: String(localized: "Match case"), target: nil, action: nil)
    private let addition = NSTextField()
    private let position = NSPopUpButton()
    private let template = NSTextField()
    private let start = NSTextField()
    private let caseMenu = NSPopUpButton()
    private let includeExtension = NSButton(checkboxWithTitle: String(localized: "Change extensions too"), target: nil, action: nil)
    private let rulesStack = NSStackView()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: String(localized: "Rename", comment: "Button: rename the items"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)

    /// `urls` in the order the window shows them, which is the order they're numbered in.
    init(urls: [URL], baseFolder: URL, undo: UndoManager?, copies: CopyProviders, history: OperationLog) {
        self.urls = urls
        self.baseFolder = baseFolder
        self.undo = undo
        self.copies = copies
        self.history = history
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "Rename \(urls.count) Items", comment: "plural"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        configureRuleControls()
        let list = makeList()
        let footer = makeFooter()
        let container = layOut(title: title, list: list, footer: footer)
        view = container
        ThemeStyle.refresh(container)
        showRuleControls()
        summary.stringValue = String(localized: "Reading \(urls.count) items…", comment: "plural")
        labelControls()
        readItems()
    }

    /// The rule menu and every rule's fields, popups and checkboxes, each reporting its changes.
    private func configureRuleControls() {
        for m in RenameRules.Mode.allCases { mode.addItem(withTitle: m.title) }
        mode.target = self
        mode.action = #selector(changed(_:))

        configure(find, placeholder: String(localized: "Find", comment: "Batch rename field: the text to replace in names"))
        configure(replacement, placeholder: String(localized: "Replace with", comment: "Batch rename field: the text that replaces it"))
        configure(addition, placeholder: String(localized: "Text to add"))
        configure(template, placeholder: "{name} {n}")
        template.stringValue = rules.template
        configure(start, placeholder: "1")
        start.stringValue = "1"
        position.addItems(withTitles: [String(localized: "after name", comment: "Batch rename: add the text after the name"),
                                       String(localized: "before name", comment: "Batch rename: add the text before the name")])
        for transform in PlanRecipe.NameTransform.allCases { caseMenu.addItem(withTitle: transform.title.capitalizedFirst) }
        caseMenu.selectItem(at: PlanRecipe.NameTransform.allCases.firstIndex(of: rules.transform) ?? 0)
        for control in [regex, matchCase, includeExtension] as [NSButton] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        for popup in [position, caseMenu] {
            popup.target = self
            popup.action = #selector(changed(_:))
        }

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 8
    }

    /// The list of old and new names.
    private func makeList() -> NSScrollView {
        let column = NSTableColumn(identifier: .init("step"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    /// The summary, Cancel and Rename.
    private func makeFooter() -> NSStackView {
        summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancel = cancelButton
        cancel.target = self
        cancel.action = #selector(cancel(_:))
        cancel.keyEquivalent = "\u{1b}"
        renameButton.target = self
        renameButton.action = #selector(apply(_:))
        renameButton.keyEquivalent = "\r"
        renameButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [summary, spacer, cancel, renameButton])
        footer.spacing = 8
        return footer
    }

    private func layOut(title: NSTextField, list scroll: NSScrollView, footer: NSStackView) -> NSView {
        let stack = NSStackView(views: [title, mode, rulesStack, includeExtension, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        ThemeStyle.bind(container, to: .content)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 640),
            scroll.heightAnchor.constraint(equalToConstant: 260),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            rulesStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        return container
    }

    private func labelControls() {
        for (field, label) in [(find, String(localized: "Find", comment: "Batch rename field: the text to replace in names")),
                               (replacement, String(localized: "Replace with", comment: "Batch rename field: the text that replaces it")),
                               (addition, String(localized: "Text to add")), (template, String(localized: "Name format")),
                               (start, String(localized: "Start numbers at"))] {
            field.setAccessibilityLabel(label)
        }
        mode.setAccessibilityLabel(String(localized: "Rename rule"))
        position.setAccessibilityLabel(String(localized: "Where to add the text"))
        caseMenu.setAccessibilityLabel(String(localized: "Change case to"))
    }

    /// The items' names and dates, read off the main thread, then the first preview.
    private func readItems() {
        Task { [weak self] in
            guard let self else { return }
            items = await PlanItem.load(urls)
            if items.isEmpty {
                summary.stringValue = String(localized: "These items couldn’t be read.")
                summary.textColor = .systemRed
                return
            }
            update(now: true)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(find)
    }

    // MARK: - Rules

    private func configure(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    }

    /// Only the selected rule's controls are shown.
    private func showRuleControls() {
        rulesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.spacing = 8
            row.alignment = .firstBaseline
            return row
        }
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            return label
        }
        switch RenameRules.Mode(rawValue: mode.indexOfSelectedItem) ?? .replace {
        case .replace:
            rulesStack.addArrangedSubview(row([label(String(localized: "Find:", comment: "Label of the text to replace in names")), find]))
            rulesStack.addArrangedSubview(row([label(String(localized: "Replace with:")), replacement]))
            rulesStack.addArrangedSubview(row([label(""), regex, matchCase]))
        case .add:
            rulesStack.addArrangedSubview(row([label(String(localized: "Add:", comment: "Label of the text to add to names")), addition, position]))
        case .format:
            rulesStack.addArrangedSubview(row([label(String(localized: "Name:", comment: "Label of the name pattern, like “{name} {n}”")), template]))
            rulesStack.addArrangedSubview(row([label(String(localized: "Start at:", comment: "Label of the first number")), start]))
            let help = NSTextField(wrappingLabelWithString: String(localized: "{name} the current name · {n} a number · {date} {time} {year} {month} {day} when it was taken or made · {camera} · {kind} · {parent} its folder",
                                                                  comment: "Keep the tokens in braces as they are: they’re what people type"))
            help.font = .systemFont(ofSize: 11)
            help.textColor = .secondaryLabelColor
            help.preferredMaxLayoutWidth = 480
            rulesStack.addArrangedSubview(row([label(""), help]))
        case .changeCase:
            rulesStack.addArrangedSubview(row([label(String(localized: "Change to:", comment: "Label of the case to change names to")), caseMenu]))
        }
        // Format keeps extensions ({name} is the name without one).
        includeExtension.isHidden = RenameRules.Mode(rawValue: mode.indexOfSelectedItem) == .format
        ThemeStyle.refresh(rulesStack, includingInputs: true)
    }

    /// The first thing to type into for the shown rule.
    private var firstField: NSView {
        switch RenameRules.Mode(rawValue: mode.indexOfSelectedItem) ?? .replace {
        case .replace: find
        case .add: addition
        case .format: template
        case .changeCase: caseMenu
        }
    }

    @objc private func changed(_ sender: Any?) {
        if sender as? NSPopUpButton === mode {
            showRuleControls()
            view.window?.makeFirstResponder(firstField)
        }
        update()
    }

    func controlTextDidChange(_ notification: Notification) {
        // Start numbers: digits only, at most six (a paste of anything else is trimmed, not silently cleared).
        if notification.object as? NSTextField === start {
            let digits = String(start.stringValue.filter(\.isASCII).filter(\.isNumber).prefix(6))
            if digits != start.stringValue { start.stringValue = digits }
        }
        update()
    }

    /// Reads the controls into the rule and rebuilds the preview: off the main thread, once typing pauses (a big
    /// selection, or a slow regular expression, mustn't hold up the keyboard).
    private func update(now: Bool = false) {
        guard !isApplying else { return }
        rules.mode = RenameRules.Mode(rawValue: mode.indexOfSelectedItem) ?? .replace
        rules.find = find.stringValue
        rules.replacement = replacement.stringValue
        rules.useRegex = regex.state == .on
        rules.matchCase = matchCase.state == .on
        rules.addition = addition.stringValue
        rules.addAtEnd = position.indexOfSelectedItem == 0
        rules.template = template.stringValue
        rules.startNumber = Int(start.stringValue).map { min(max($0, RenameRules.startRange.lowerBound), RenameRules.startRange.upperBound) } ?? 1
        let allTransforms = PlanRecipe.NameTransform.allCases
        let transformIndex = min(max(0, caseMenu.indexOfSelectedItem), max(0, allTransforms.count - 1))
        rules.transform = allTransforms[transformIndex]
        rules.includeExtension = includeExtension.state == .on
        guard !items.isEmpty else { return }
        previewTask?.cancel()
        let rules = rules, items = items, baseFolder = baseFolder
        renameButton.isEnabled = false
        previewTask = Task { [weak self] in
            if !now { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let result = await Self.preview(rules, items, baseFolder)
            guard !Task.isCancelled, let self, !isApplying else { return }
            show(result)
        }
    }

    @concurrent
    private static func preview(_ rules: RenameRules, _ items: [PlanItem], _ baseFolder: URL) async -> Result<Plan, RenameRules.Problem> {
        rules.plan(for: items, baseFolder: baseFolder)
    }

    private func show(_ result: Result<Plan, RenameRules.Problem>) {
        switch result {
        case .success(let plan):
            self.plan = plan
            rows = plan.steps + plan.excluded
            let renames = plan.steps.count
            var parts = [renames == 0 ? String(localized: "No names change") : String(localized: "\(renames) items will be renamed", comment: "plural")]
            if !plan.excluded.isEmpty {
                parts.append(String(localized: "\(plan.excluded.count) can’t be renamed", comment: "plural; after “N items will be renamed”"))
            }
            summary.stringValue = parts.joined(separator: " · ")
            summary.textColor = plan.excluded.isEmpty ? .secondaryLabelColor : .systemOrange
            renameButton.isEnabled = renames > 0
        case .failure(let problem):
            plan = nil
            rows = []
            summary.stringValue = problem.message
            summary.textColor = .systemRed
            renameButton.isEnabled = false
        }
        table.reloadData()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("RenameRow")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PlanRowView ?? {
            let view = PlanRowView()
            view.identifier = id
            return view
        }()
        cell.configure(rows[row], base: baseFolder, editable: false) { _ in }
        return cell
    }

    // MARK: - Actions

    @objc private func cancel(_ sender: Any?) {
        guard !isApplying else { return }
        previewTask?.cancel()
        dismiss(nil)
    }

    @objc private func apply(_ sender: Any?) {
        guard !isApplying, let plan, !plan.steps.isEmpty else { return }
        isApplying = true
        previewTask?.cancel()
        // Nothing changes under the rename: every control is off until it's done.
        renameButton.isEnabled = false
        for control in [mode, find, replacement, regex, matchCase, addition, position, template, start, caseMenu, includeExtension] as [NSControl] {
            control.isEnabled = false
        }
        cancelButton.isEnabled = false
        summary.stringValue = String(localized: "Renaming…")
        let count = plan.steps.count
        Task { [weak self] in
            guard let self else { return }
            // History records the English "Rename" (its pencil icon, translated when shown); the Edit menu says how many.
            let outcome = await PlanExecutor.apply(plan, actionName: "Rename", undoName: String(localized: "Rename \(count) Items", comment: "plural"),
                                                   undo: undo, copies: copies, history: history)
            let window = view.window?.sheetParent
            dismiss(nil)
            onApplied?(outcome.results)
            if !outcome.failures.isEmpty, let window {
                let alert = NSAlert()
                alert.messageText = String(localized: "Some items couldn’t be renamed.")
                alert.informativeText = outcome.failures.prefix(5).joined(separator: "\n")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}

private extension String {
    /// "spaces → dashes" → "Spaces → dashes".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

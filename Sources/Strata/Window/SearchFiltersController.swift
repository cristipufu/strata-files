import AppKit
import StrataTheme

/// Native form controls inside a transient popover; applying is a separate, pane-bound decision.
final class SearchFiltersController: NSViewController {
    private var draft: SearchFilterDraft
    private let context: SearchFilterContext
    private let kind = NSPopUpButton()
    private let fields = (0..<4).map { _ in NSComboBox() }
    private let problem = NSTextField(wrappingLabelWithString: "")
    private weak var popover: NSPopover?

    init(query: String, context: SearchFilterContext) {
        draft = SearchFilterDraft(query); self.context = context
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        kind.addItem(withTitle: String(localized: "Any Kind"))
        kind.lastItem?.representedObject = ""
        let values = ["folder", "document", "pdf", "text", "image", "video", "audio", "archive", "code", "spreadsheet", "presentation", "app", "diskimage", "book", "comic"]
        for (item, value) in zip(SearchFilter.Kind.allCases, values) {
            kind.addItem(withTitle: item.title); kind.lastItem?.representedObject = value
        }
        if !draft.kind.isEmpty && !kind.itemArray.contains(where: { $0.representedObject as? String == draft.kind }) {
            kind.addItem(withTitle: draft.kind); kind.lastItem?.representedObject = draft.kind
        }
        kind.select(kind.itemArray.first { $0.representedObject as? String == draft.kind })
        let titles = [String(localized: "Extension"), String(localized: "Size"), String(localized: "Date Modified"), String(localized: "Downloaded From")]
        let presets = [["pdf", "png,jpg", "swift"], [">10mb", "<1gb", "1mb..100mb", "empty"], ["today", "yesterday", "thisweek", "thismonth"], ["github.com"]]
        let current = [draft.extensions, draft.size, draft.modified, draft.source]
        var rows: [[NSView]] = [[NSTextField(labelWithString: String(localized: "Kind")), kind]]
        for index in fields.indices {
            let field = fields[index]
            field.addItems(withObjectValues: presets[index]); field.stringValue = current[index]
            ThemeStyle.bindInput(field)
            field.setAccessibilityLabel(titles[index]); field.widthAnchor.constraint(equalToConstant: 250).isActive = true
            rows.append([NSTextField(labelWithString: titles[index]), field])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let help = NSTextField(wrappingLabelWithString: String(localized: "Download origin uses Spotlight and requires saved source metadata."))
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        problem.font = .systemFont(ofSize: 11); problem.textColor = .secondaryLabelColor; problem.isHidden = true
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: String(localized: "Apply"), target: self, action: #selector(applyClicked))
        apply.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, apply])
        let stack = NSStackView(views: [grid, help, problem, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let canvas = ThemeSurfaceView(); canvas.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -18),
            help.widthAnchor.constraint(equalTo: grid.widthAnchor), problem.widthAnchor.constraint(equalTo: grid.widthAnchor), buttons.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        view = canvas
        preferredContentSize = canvas.fittingSize
    }

    @objc private func applyClicked() {
        draft.kind = kind.selectedItem?.representedObject as? String ?? ""
        draft.extensions = fields[0].stringValue; draft.size = fields[1].stringValue
        draft.modified = fields[2].stringValue; draft.source = fields[3].stringValue
        guard let query = draft.query() else {
            problem.stringValue = String(localized: "Check the size and date filters. Download origin cannot be combined with name patterns, exclusions or folder filters.")
            problem.isHidden = false
            preferredContentSize = view.fittingSize
            return
        }
        _ = context.apply(query)
        popover?.performClose(nil)
    }
    @objc private func cancelClicked() { popover?.performClose(nil) }

    func show(from anchor: NSView) {
        let popover = NSPopover()
        popover.contentViewController = self; popover.behavior = .transient
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}

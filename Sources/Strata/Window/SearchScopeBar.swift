import AppKit

/// Shown under the toolbar while searching: where to search, how many matches, and saving the search.
final class SearchScopeBar: NSSplitViewItemAccessoryViewController {
    var onScopeChange: ((_ everywhere: Bool) -> Void)?
    var onSave: (() -> Void)?
    /// Match Case was switched (the search's `case:`).
    var onMatchCase: ((Bool) -> Void)?
    var onFilters: ((NSView) -> Void)?

    private let scope = NSSegmentedControl()
    private let matchCase = NSButton(checkboxWithTitle: String(localized: "Match Case"), target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let save = NSButton()
    private let filters = NSButton()

    override func loadView() {
        scope.segmentStyle = .automatic
        scope.trackingMode = .selectOne
        scope.segmentCount = 2
        scope.setLabel(String(localized: "Everywhere", comment: "Search scope: the whole index"), forSegment: 0)
        scope.selectedSegment = 0
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(scopeChanged)

        matchCase.controlSize = .small
        matchCase.font = .systemFont(ofSize: 11)
        matchCase.target = self
        matchCase.action = #selector(matchCaseChanged)
        matchCase.toolTip = String(localized: "Names must match the letters’ case and accents exactly (case: in the search)", comment: "Keep case: as is, it is search syntax")

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        save.bezelStyle = .accessoryBarAction
        save.controlSize = .small
        save.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        save.imagePosition = .imageLeading
        save.title = String(localized: "Save Search")
        save.target = self
        save.action = #selector(saveClicked)

        filters.title = String(localized: "Filters…")
        filters.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        filters.imagePosition = .imageLeading
        filters.bezelStyle = .accessoryBarAction
        filters.controlSize = .small
        filters.target = self
        filters.action = #selector(filtersClicked)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [scope, matchCase, summary, spacer, filters, save])
        stack.spacing = 10
        // In a narrow pane the summary truncates, then Match Case steps aside, and what's left clips: the bar never holds
        // the pane (and the window) wider. It's laid out even while hidden.
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: matchCase)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        view = ThemeAccessoryView.bar(holding: stack)
    }

    /// `caseApplies`: off for searches Spotlight or a plain-English reading answers (case means nothing there).
    func configure(folderName: String?, everywhere: Bool, matchCase: Bool, caseApplies: Bool) {
        loadViewIfNeeded()
        setMatchCase(matchCase, applies: caseApplies)
        if let folderName {
            scope.segmentCount = 2
            scope.setLabel(String(localized: "“\(folderName)”", comment: "Search scope: the current folder, by name in quotes"), forSegment: 1)
        } else {
            scope.segmentCount = 1
        }
        scope.selectedSegment = everywhere || folderName == nil ? 0 : 1
    }

    func setMatchCase(_ on: Bool, applies: Bool) {
        loadViewIfNeeded()
        matchCase.state = on ? .on : .off
        matchCase.isHidden = !applies && !on
    }

    func setSummary(_ text: String) {
        loadViewIfNeeded()
        summary.stringValue = text
    }

    @objc private func scopeChanged() {
        onScopeChange?(scope.selectedSegment == 0)
    }

    @objc private func matchCaseChanged() {
        onMatchCase?(matchCase.state == .on)
    }

    @objc private func saveClicked() {
        onSave?()
    }

    @objc private func filtersClicked() { onFilters?(filters) }
}

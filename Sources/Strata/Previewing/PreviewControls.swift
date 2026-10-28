import AppKit

/// Native controls stay on the preview's surface; AppKit retains the search bezel, focus ring and menu behavior.
@MainActor final class PreviewControls: NSStackView, NSSearchFieldDelegate, NSMenuDelegate {
    let search = NSSearchField()
    private let openButton = NSButton()
    private let showButton = NSButton()
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    let modeControl = NSSegmentedControl()
    let sizeSlider = NSSlider(value: 80, minValue: 32, maxValue: 256, target: nil, action: nil)
    let backButton = NSButton()
    var onMode: ((PreviewViewMode) -> Void)?
    var onIconSize: ((Double) -> Void)?
    var onBack: (() -> Void)?
    private var icons = false
    private var target: PreviewCommandTarget?
    var canPerform: ((PreviewAction, PreviewCommandTarget) -> Bool)?
    var onAction: ((PreviewAction, PreviewCommandTarget) -> Void)?
    var onQuery: ((String) -> Void)?
    var onOrder: ((PreviewListing.Key) -> Void)?
    var order = PreviewListing.Order()

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        ThemeStyle.bind(self, to: .content)
        modeControl.segmentCount = 2
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        for (index, symbol, label) in [(0, "list.bullet", String(localized: "View as List")), (1, "square.grid.2x2", String(localized: "View as Icons"))] {
            modeControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            modeControl.setToolTip(label, forSegment: index)
        }
        modeControl.setAccessibilityLabel(String(localized: "View"))
        sizeSlider.controlSize = .small
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.setAccessibilityLabel(String(localized: "Icon size"))
        sizeSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Back"))
        backButton.controlSize = .small
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(back(_:))
        backButton.toolTip = String(localized: "Back")
        search.placeholderString = String(localized: "Filter")
        search.setAccessibilityLabel(String(localized: "Filter"))
        search.toolTip = String(localized: "Filters loaded items only.", comment: "Preview filter never searches or downloads entire folders")
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.delegate = self
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        ThemeStyle.bind(search, to: .preview)
        for (button, action) in [(openButton, PreviewAction.open), (showButton, .showInStrata)] {
            button.title = action.title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = #selector(run(_:))
            button.tag = PreviewAction.allCases.firstIndex(of: action) ?? 0
        }
        more.controlSize = .small
        more.bezelStyle = .rounded
        more.menu?.delegate = self
        more.setAccessibilityLabel(String(localized: "Actions", comment: "Accessibility label for the preview actions menu"))
        addArrangedSubview(modeControl)
        addArrangedSubview(backButton)
        addArrangedSubview(search)
        addArrangedSubview(sizeSlider)
        addArrangedSubview(openButton)
        addArrangedSubview(showButton)
        addArrangedSubview(more)
        update(nil)
        updateView(mode: .list, size: 80, canBrowse: false, canGoBack: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateView(mode: PreviewViewMode, size: Double, canBrowse: Bool, canGoBack: Bool) {
        icons = mode == .icons
        modeControl.selectedSegment = mode.rawValue
        modeControl.isEnabled = canBrowse
        sizeSlider.doubleValue = size
        sizeSlider.isHidden = !icons || !canBrowse
        backButton.isHidden = !icons || !canBrowse
        backButton.isEnabled = canGoBack
        needsLayout = true
    }

    override func layout() {
        showButton.isHidden = icons && bounds.width < 800
        super.layout()
    }

    @objc func modeChanged(_ sender: NSSegmentedControl) {
        guard let mode = PreviewViewMode(rawValue: sender.selectedSegment) else { return }
        onMode?(mode)
    }

    @objc func sizeChanged(_ sender: NSSlider) { if sender.doubleValue.isFinite { onIconSize?(sender.doubleValue) } }
    @objc private func back(_ sender: Any?) { onBack?() }

    func update(_ target: PreviewCommandTarget?) {
        self.target = target
        openButton.isEnabled = target.map { canPerform?(.open, $0) == true } ?? false
        showButton.isEnabled = target.map { canPerform?(.showInStrata, $0) == true } ?? false
        more.isEnabled = target != nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        more.menu = menu
        menuNeedsUpdate(menu)
    }

    func controlTextDidChange(_ notification: Notification) { onQuery?(search.stringValue) }
    func searchFieldDidEndSearching(_ sender: NSSearchField) { onQuery?(sender.stringValue) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        heading.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        menu.addItem(heading)
        actionItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(sortItem())
    }

    func actionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        actionItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(sortItem())
        return menu
    }

    private func sortItem() -> NSMenuItem {
        let sort = NSMenuItem(title: String(localized: "Sort By"), action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        let titles: [(PreviewListing.Key, String)] = [(.name, String(localized: "Name")), (.kind, String(localized: "Kind")),
                                                     (.modified, String(localized: "Date Modified")), (.size, String(localized: "Size"))]
        for (key, title) in titles {
            let item = NSMenuItem(title: title, action: #selector(chooseSort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = key == order.key ? .on : .off
            if key == order.key { item.image = NSImage(systemSymbolName: order.ascending ? "arrow.up" : "arrow.down", accessibilityDescription: nil) }
            choices.addItem(item)
        }
        sort.submenu = choices
        return sort
    }

    @objc func chooseSort(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? PreviewListing.Key else { return }
        onOrder?(key)
    }

    private func actionItems() -> [NSMenuItem] {
        PreviewAction.allCases.enumerated().map { index, action in
            let item = NSMenuItem(title: action.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = target
            item.isEnabled = target.map { canPerform?(action, $0) == true } ?? false
            return item
        }
    }

    @objc func run(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag ?? -1
        guard PreviewAction.allCases.indices.contains(tag),
              let target = (sender as? NSMenuItem)?.representedObject as? PreviewCommandTarget ?? target else { return }
        let action = PreviewAction.allCases[tag]
        guard canPerform?(action, target) == true else { return }
        onAction?(action, target)
    }
}

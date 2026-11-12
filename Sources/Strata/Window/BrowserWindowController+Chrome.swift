import AppKit

/// Tabs above the address bar: the toolbar hides (it stays attached, so its items and saved layout are kept), the
/// native tab bar stays shown even with one tab, and the address row holds the window's path bar and search.
extension BrowserWindowController {
    var chromeLayout: WindowChromeLayout {
        WindowChromeLayout.decide(explorerTabs: services.preferences.explorerTabs, dualPane: isDualPane,
                                  dualPaneAddressBars: services.preferences.dualPaneAddressBars)
    }

    func connectAddressRow() {
        split.addressRow.connect(to: self)
        split.addressRow.transfers.onReveal = { [weak self] job in self?.navigate(to: job.destination, select: job.createdItems.last) }
    }

    @objc func windowLayoutChanged() {
        applyChromeLayout()
    }

    func applyChromeLayout() {
        guard !isClosed, let window, let toolbar = window.toolbar else { return }
        let layout = chromeLayout, row = split.addressRow
        guard layout != appliedChrome else { return }
        let hadRow = appliedChrome?.addressRowVisible == true
        if layout.addressRowVisible, !hadRow {
            toolbarVisibleBeforeRow = toolbar.isVisible
            handOverSearch(from: toolbarItems.search?.searchField, to: row.search)
            pathBar.cancelEditing()
            toolbarItems.pathBar?.view = pathBarStandIn
            pathBar.isInAddressRow = true
            row.hold(pathBar)
            toolbar.isVisible = false
            row.isHidden = false
        } else if !layout.addressRowVisible, hadRow {
            handOverSearch(from: row.search, to: toolbarItems.search?.searchField)
            if let focused = window.firstResponder as? NSView, focused.isDescendant(of: row.view) { focusList() }
            pathBar.cancelEditing()
            row.release(pathBar)
            pathBar.isInAddressRow = false
            pathBar.isHidden = false
            toolbarItems.pathBar?.view = pathBar
            row.isHidden = true
            toolbar.isVisible = toolbarVisibleBeforeRow
        }
        if layout.addressRowVisible {
            if !layout.rowShowsPathBar, pathBar.isEditing { pathBar.cancelEditing() }
            pathBar.isHidden = !layout.rowShowsPathBar
            row.showsPathBar(layout.rowShowsPathBar)
        }
        appliedChrome = layout
        validateAddressRow()
        applyTabBar(layout)
    }

    /// The field the layout hides gives up typing, and the one it shows takes over the active search's query.
    private func handOverSearch(from hidden: NSSearchField?, to shown: NSSearchField?) {
        guard let window else { return }
        if WindowChromeLayout.isEditing(hidden, firstResponder: window.firstResponder) { focusList() }
        if let shown, let text = WindowChromeLayout.searchText(for: destination), shown.stringValue != text {
            shown.stringValue = text
        }
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        chromeLayout.fullScreenOptions(proposed: proposedOptions)
    }

    /// The row's buttons are enabled exactly when their menu commands are.
    func validateAddressRow() {
        guard appliedChrome?.addressRowVisible == true else { return }
        split.addressRow.validate { validateMenuItem($0.menuItem()) }
    }

    /// Only a shown window's tab group has a tab bar to show; the window boundary asks AppKit (never in tests, since
    /// AppKit saves Show Tab Bar in the app's defaults).
    func applyTabBar(_ layout: WindowChromeLayout) {
        guard let window, let group = window.tabGroup else { return }
        let preferences = services.preferences
        switch WindowChromeLayout.tabBarStep(alwaysShown: layout.tabBarAlwaysShown, isVisible: group.isTabBarVisible,
                                             tabs: group.windows.count, shownByLayout: preferences.tabBarShownByLayout) {
        case .show:
            preferences.tabBarShownByLayout = true
            services.windows.toggleTabBar(window)
        case .hide:
            preferences.tabBarShownByLayout = false
            services.windows.toggleTabBar(window)
        case .none: break
        }
    }
}

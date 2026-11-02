import AppKit

/// A zero-height accessory follows the title bar when AppKit moves it to the full-screen toolbar window.
package final class ToolbarThemeController: NSTitlebarAccessoryViewController {
    private static let navigation = NSMapTable<NSToolbarItem, NavigationItemTheme>.weakToStrongObjects()
    private weak var browserWindow: NSWindow?
    private var toolbarHost: ToolbarThemeHost?
    private var refreshPending = false
    private var refreshing = false
    private var changingFullScreen = false
    private var departing: [ToolbarThemeHost] = []
    private let backdrops = ToolbarBackdropTint()

    package init(window: NSWindow) {
        browserWindow = window
        super.init(nibName: nil, bundle: nil)
        automaticallyAdjustsSize = false
        layoutAttribute = .bottom
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: window)
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(willChangeFullScreen), name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(didChangeFullScreen), name: name, object: window)
        }
        if let split = window.contentViewController as? any ThemeSplitWindowContent {
            NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func viewDidAppear() {
        super.viewDidAppear()
        scheduleRefresh()
    }

    @objc private func resized() { scheduleRefresh() }

    @objc private func willChangeFullScreen() {
        discardDepartures()
        changingFullScreen = true
        refresh()
    }

    @objc private func didChangeFullScreen() { finishFullScreenTransition() }

    package func finishFullScreenTransition() {
        changingFullScreen = false
        refresh()
        discardDepartures()
        if toolbarHost == nil {
            backdrops.restore()
            if let browserWindow { backdrops.prepare(in: browserWindow) }
        }
    }

    package override func loadView() {
        let probe = ToolbarThemeProbe(frame: .zero)
        probe.onMove = { [weak self] in self?.scheduleRefresh() }
        probe.onWindow = { [weak self] host in
            guard let self, let host else { return }
            refreshToolbarWindow(detachedToolbarWindow(from: host))
        }
        view = probe
    }

    private func detachedToolbarWindow(from accessory: NSWindow?) -> NSWindow? {
        guard let browserWindow else { return nil }
        if let accessory, accessory !== browserWindow { return accessory }
        // A zero-height accessory can stay in the browser while AppKit moves the actual toolbar items.
        return browserWindow.toolbar?.items.compactMap { $0.view?.window }.first { $0 !== browserWindow }
    }

    package static func apply(to window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        for item in window.toolbar?.items ?? [] where item.itemIdentifier == .back || item.itemIdentifier == .forward {
            applyNavigation(to: item)
        }
        let controller: ToolbarThemeController
        if let existing = window.titlebarAccessoryViewControllers.compactMap({ $0 as? ToolbarThemeController }).first {
            controller = existing
        } else {
            controller = ToolbarThemeController(window: window)
            window.addTitlebarAccessoryViewController(controller)
        }
        if ThemeStyle.colorsSurfaces { controller.refresh() }
        else { controller.finishFullScreenTransition() }
    }

    package static func applyNavigation(to item: NSToolbarItem) {
        if navigation.object(forKey: item) == nil { navigation.setObject(NavigationItemTheme(item), forKey: item) }
        navigation.object(forKey: item)?.apply(to: item)
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshPending = false
            refresh()
        }
    }

    package func refresh() {
        guard let browserWindow else { return }
        if ThemeStyle.colorsSurfaces { backdrops.prepare(in: browserWindow) }
        else { backdrops.restore() }
        Self.refreshHeader(of: browserWindow, excluding: browserWindow.contentView, restoring: !ThemeStyle.colorsSurfaces)
        let accessory = isViewLoaded ? view.window : nil
        if let host = detachedToolbarWindow(from: accessory) { refreshToolbarWindow(host) }
        else if accessory != nil || !changingFullScreen { refreshToolbarWindow(nil) }
    }

    package func refreshToolbarWindow(_ host: NSWindow?) {
        guard let browserWindow, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let target = host === browserWindow ? nil : host
        if toolbarHost?.window !== target {
            if changingFullScreen, ThemeStyle.colorsSurfaces, let previous = toolbarHost {
                // AppKit crossfades the hosts. Keep the old material tinted until the animation finishes.
                departing.append(previous)
            } else {
                toolbarHost?.restore()
                if !changingFullScreen { backdrops.restore() }
            }
            toolbarHost = nil
            if let target {
                if let index = departing.firstIndex(where: { $0.window === target }) {
                    // A canceled transition can return to a still-tinted host; retain its original native background.
                    toolbarHost = departing.remove(at: index)
                } else {
                    toolbarHost = ToolbarThemeHost(window: target, backdrops: backdrops)
                }
            }
        }
        ThemeStyle.updateTitlebar(in: browserWindow, detached: target != nil || (changingFullScreen && !departing.isEmpty))
        backdrops.prepare(in: browserWindow)
        toolbarHost?.apply()
        if !ThemeStyle.colorsSurfaces {
            discardDepartures()
            backdrops.restore()
        }
    }

    private func discardDepartures() {
        let hadDepartures = !departing.isEmpty
        for previous in departing {
            if previous.window !== toolbarHost?.window {
                previous.restore()
            }
        }
        departing.removeAll()
        // AppKit may move the same section into the new host. Restoring the departing host's
        // saved backing must not leave that section gray in its new window.
        if hadDepartures { toolbarHost?.apply() }
    }

    /// Refresh only title-bar materials. Native controls and the browser’s content keep their own drawing and actions.
    /// Leave AppKit's header above the colored content; an opaque backing here creates a seam when focus changes.
    package static func refreshHeader(of window: NSWindow, excluding content: NSView?, restoring: Bool = false, withinWindow: Bool = false) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        func visit(_ view: NSView) {
            guard view !== content else { return }
            guard !(view is NSControl) else { return }
            if restoring { ThemeStyle.restoreHeaderMaterial(view) }
            else { ThemeStyle.tintHeaderMaterial(view, withinWindow: withinWindow) }
            view.needsDisplay = true
            for child in view.subviews { visit(child) }
        }
        visit(root)
    }
}

private final class ToolbarThemeProbe: NSView {
    var onMove: (() -> Void)?
    var onWindow: ((NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        onWindow?(newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
        onMove?()
    }

    override func layout() {
        super.layout()
        onWindow?(window)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onMove?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onWindow?(window)
        onMove?()
    }
}

private final class ToolbarThemeHost {
    weak var window: NSWindow?
    private let background: NSColor
    private let transparent: Bool
    private let canvas = ThemeSurfaceView()
    private let backdrops: ToolbarBackdropTint

    init(window: NSWindow, backdrops: ToolbarBackdropTint) {
        self.window = window
        self.backdrops = backdrops
        background = window.backgroundColor
        transparent = window.titlebarAppearsTransparent
        canvas.role = .content
        canvas.ignoresMouse = true
        canvas.autoresizingMask = [.width, .height]
    }

    func apply() {
        guard let window else { return }
        // The full-screen content view can paint its own white background, independent of NSWindow.backgroundColor.
        // Put the canvas inside that view, behind every native header and control, rather than above the chrome.
        if ThemeStyle.colorsSurfaces, let content = window.contentView {
            if canvas.superview !== content {
                canvas.frame = content.bounds
                content.addSubview(canvas, positioned: .below, relativeTo: nil)
            }
            canvas.needsDisplay = true
        } else {
            canvas.removeFromSuperview()
        }
        window.backgroundColor = ThemeStyle.colorsSurfaces ? ThemeStyle.surface(.content) : background
        // The auxiliary window owns native sidebar header sections, including their rounded masks.
        // Tint underneath them without suppressing their backgrounds.
        if window.titlebarAppearsTransparent != transparent { window.titlebarAppearsTransparent = transparent }
        backdrops.apply(in: window)
        ToolbarThemeController.refreshHeader(of: window, excluding: nil, restoring: !ThemeStyle.colorsSurfaces, withinWindow: true)
    }

    func restore() {
        guard let window else { return }
        window.backgroundColor = background
        window.titlebarAppearsTransparent = transparent
        canvas.removeFromSuperview()
        ToolbarThemeController.refreshHeader(of: window, excluding: nil, restoring: true)
    }
}

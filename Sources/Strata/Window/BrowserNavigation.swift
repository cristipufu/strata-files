import AppKit

/// Pointer navigation belongs to the window receiving the event, and to the pane where the gesture began.
final class BrowserNavigation {
    nonisolated enum Direction: Equatable, Sendable { case back, forward }
    typealias SwipeUpdate = @MainActor (CGFloat, NSEvent.Phase, Bool) -> Bool
    typealias SwipeTracker = @MainActor (NSEvent, CGFloat, CGFloat, @escaping SwipeUpdate) -> Void

    private weak var owner: BrowserWindowController?
    private var attempt = UUID()

    init(owner: BrowserWindowController) { self.owner = owner }

    func cancel() { attempt = UUID() }

    nonisolated static func direction(button: Int) -> Direction? {
        switch button {
        case 3: .back
        case 4: .forward
        default: nil
        }
    }

    nonisolated static func direction(x: CGFloat, y: CGFloat, rightToLeft: Bool = false) -> Direction? {
        guard x.isFinite, y.isFinite, abs(x) > abs(y) else { return nil }
        return (x > 0) != rightToLeft ? .back : .forward
    }

    private var rightToLeft: Bool { owner?.window?.contentView?.userInterfaceLayoutDirection == .rightToLeft }
    private var isEditingText: Bool {
        guard let editor = owner?.window?.firstResponder as? NSTextView else { return false }
        return editor.isFieldEditor || editor.isEditable
    }

    func swipeDirection(x: CGFloat, y: CGFloat) -> Direction? { Self.direction(x: x, y: y, rightToLeft: rightToLeft) }

    private func pane(at point: NSPoint) -> Pane? {
        guard let owner, !owner.isClosed, let window = owner.window, window.attachedSheet == nil else { return nil }
        return owner.panes.first { pane in
            let view = pane.host.view
            return !view.isHiddenOrHasHiddenAncestor && view.visibleRect.contains(view.convert(point, from: nil))
        }
    }

    @discardableResult func handle(_ direction: Direction, at point: NSPoint) -> Bool {
        guard let owner, let pane = pane(at: point) else { return false }
        cancel()
        return navigate(direction, owner: owner, pane: pane)
    }

    private func navigate(_ direction: Direction, owner: BrowserWindowController, pane: Pane) -> Bool {
        guard pane.history.canGo(direction) else { return false }
        guard owner.window?.makeFirstResponder(pane.browser.focusView) == true else { return false }
        return owner.navigateHistory(direction, in: pane)
    }

    func canTrackSwipe(at point: NSPoint) -> Bool {
        guard !isEditingText, let pane = pane(at: point), pane.browser.effectiveMode != .columns, pane.browser.effectiveMode != .gallery else { return false }
        return pane.history.canGo(.back) || pane.history.canGo(.forward)
    }

    @discardableResult
    func beginSwipe(_ event: NSEvent, enabled: Bool = NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                    track: SwipeTracker = BrowserNavigation.track) -> Bool {
        guard enabled, event.type == .scrollWheel, event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty, event.phase.contains(.began) || event.phase.contains(.changed),
              canTrackSwipe(at: event.locationInWindow), let pane = pane(at: event.locationInWindow),
              let direction = swipeDirection(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
              pane.history.canGo(direction) else { return false }
        cancel()
        let id = attempt
        let revision = pane.navigationRevision, browserRevision = pane.browser.navigationRevision
        let mode = pane.browser.effectiveMode
        let sign: CGFloat = rightToLeft ? -1 : 1
        let back = pane.history.canGo(.back) ? sign : 0
        let forward = pane.history.canGo(.forward) ? -sign : 0
        let minimum = min(back, forward), maximum = max(back, forward)
        var finished = false
        track(event, minimum, maximum) { [weak self, weak pane] amount, phase, complete in
            guard !finished, let self, let owner, let pane, !owner.isClosed, attempt == id,
                  owner.window != nil, owner.window?.attachedSheet == nil, !isEditingText,
                  owner.panes.contains(where: { $0 === pane }), pane.browser.effectiveMode == mode,
                  pane.navigationRevision == revision, pane.browser.navigationRevision == browserRevision else { return true }
            if phase.contains(.cancelled) { finished = true; return true }
            guard complete else { return false }
            finished = true
            // AppKit settles a completed swipe at -1, 0 (cancelled), or 1, including a quick flick.
            guard amount.isFinite, abs(amount) >= 0.5 else { return true }
            _ = navigate(amount * sign > 0 ? .back : .forward, owner: owner, pane: pane)
            return true
        }
        return true
    }

    private static func track(_ event: NSEvent, _ minimum: CGFloat, _ maximum: CGFloat,
                              _ update: @escaping SwipeUpdate) {
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: minimum, max: maximum) {
            amount, phase, complete, stop in
            stop.pointee = ObjCBool(update(amount, phase, complete))
        }
    }
}

/// AppKit keeps ordinary event routing and scrolling; only browser navigation gets an earlier opportunity.
final class BrowserWindow: NSWindow {
    weak var navigation: BrowserNavigation?

    override func sendEvent(_ event: NSEvent) {
        if (event.type == .rightMouseDown || event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
           toolbar != nil, event.locationInWindow.y >= contentLayoutRect.maxY,
           event.window == nil || event.window === self {
            BrowserToolbar.withAlignedContextMenu { super.sendEvent(event) }
            return
        }
        if (event.type == .otherMouseUp || event.type == .swipe), (event.window == nil || event.window === self) {
            if event.type == .otherMouseUp, let direction = BrowserNavigation.direction(button: event.buttonNumber),
               navigation?.handle(direction, at: event.locationInWindow) == true { return }
            if event.type == .swipe, let direction = navigation?.swipeDirection(x: event.deltaX, y: event.deltaY),
               navigation?.handle(direction, at: event.locationInWindow) == true { return }
        }
        super.sendEvent(event)
    }

    override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
        guard axis == .horizontal, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              let event = NSApp.currentEvent, event.window === self else { return false }
        return navigation?.canTrackSwipe(at: event.locationInWindow) == true
    }

    override func scrollWheel(with event: NSEvent) {
        if (event.window == nil || event.window === self), navigation?.beginSwipe(event) == true { return }
        super.scrollWheel(with: event)
    }
}

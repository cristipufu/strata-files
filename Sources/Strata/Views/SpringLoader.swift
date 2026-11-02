import AppKit

/// Finder's spring-loaded folders: a drag that rests on a folder opens it, so files can be dropped deeper without
/// letting go. Uses the delay set in System Settings ▸ Accessibility ▸ Pointer Control, and does nothing when spring
/// loading is off there.
///
/// Drop targets report the folder under the pointer on every drag update (nil over anything else). Once the pointer
/// has stayed on it for the delay, the folder's highlight blinks and it opens. After that the pointer has to move
/// before anything springs again, so a still pointer doesn't keep diving into whatever lands under it.
@MainActor
final class SpringLoader {
    private weak var view: NSView?
    private let open: (_ folder: URL, _ drag: Int) -> Void
    private let frame: (URL) -> NSRect?
    private var folder: URL?
    private var drag = 0
    private var timer: Timer?
    /// Where the pointer was (screen coordinates) when a folder last opened.
    private var openedAt: NSPoint?
    private var flash: NSView?

    /// `view` is the drop target: the folder only opens while the pointer is still over it. `frame` gives the folder's
    /// rectangle in `view`, to blink before opening. `open` gets the drag's sequence number, so a whole dive can be
    /// told apart from the next drag.
    init(view: NSView, frame: @escaping (URL) -> NSRect?, open: @escaping (_ folder: URL, _ drag: Int) -> Void) {
        self.view = view
        self.frame = frame
        self.open = open
    }

    /// The folder under the pointer; nil over anything else (a file, the background, one of the dragged items).
    func hover(_ url: URL?, drag: Int) {
        if let openedAt {
            let now = NSEvent.mouseLocation
            guard hypot(now.x - openedAt.x, now.y - openedAt.y) > 4 else { return }
            self.openedAt = nil
        }
        guard url?.fileViewKey != folder?.fileViewKey else { return }
        stop()
        guard let url, Self.isEnabled else { return }
        folder = url
        self.drag = drag
        schedule(after: Self.delay) { [weak self] in self?.blink() }
    }

    /// The drag left, ended or dropped.
    func cancel() {
        stop()
        openedAt = nil
    }

    /// Whether springing into `url` is worth it: a folder you can read, that won't pop a privacy prompt mid-drag (one
    /// you couldn't answer while holding the mouse button).
    /// What the disk says comes from `DragFacts`: this is asked on every move of the pointer.
    static func canOpen(_ url: URL, browsing directory: URL?, during info: NSDraggingInfo) -> Bool {
        guard DragFacts.of(info).opens(url) else { return false }
        return !Privacy.measuringWouldPrompt(url, browsing: directory ?? URL(fileURLWithPath: "/"))
    }

    // MARK: - Private

    private func stop() {
        timer?.invalidate()
        timer = nil
        folder = nil
        flash?.removeFromSuperview()
        flash = nil
    }

    /// A drag runs the run loop in event-tracking mode, which a default-mode timer would wait out.
    private func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Two quick blinks of the folder, like Finder, then it opens.
    private func blink() {
        guard let folder, let view, pointerIsInside(view) else { return stop() }
        guard let rect = frame(folder), !rect.isEmpty else { return fire() }
        let highlight = NSView(frame: rect)
        highlight.wantsLayer = true
        // Dims the folder (and its drop highlight) on and off: visible on the list's solid highlight and on icons alike.
        var color = ThemeStyle.surface(.content).cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = ThemeStyle.surface(.content).withAlphaComponent(0.65).cgColor
        }
        highlight.layer?.backgroundColor = color
        highlight.layer?.cornerRadius = 6
        view.addSubview(highlight)
        flash = highlight
        var steps = [false, true]
        func next() {
            guard flash === highlight else { return }
            guard !steps.isEmpty else { return fire() }
            highlight.isHidden = !steps.removeFirst()
            schedule(after: 0.08) { next() }
        }
        schedule(after: 0.08) { next() }
    }

    private func fire() {
        guard let folder, let view else { return stop() }
        let drag = drag
        stop()
        // The drag may have moved to another view without this one hearing about it.
        guard pointerIsInside(view) else { return }
        openedAt = NSEvent.mouseLocation
        open(folder, drag)
    }

    private func pointerIsInside(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return view.visibleRect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true
    }

    /// The Pointer Control setting, 0 (instant) to 2 seconds; half a second when it was never changed.
    private static var delay: TimeInterval {
        guard UserDefaults.standard.object(forKey: "com.apple.springing.delay") != nil else { return 0.5 }
        return min(max(UserDefaults.standard.double(forKey: "com.apple.springing.delay"), 0), 2)
    }
}

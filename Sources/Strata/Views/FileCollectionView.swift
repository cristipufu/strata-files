import AppKit

/// What a file collection view's keys and focus go to: its controller.
protocol FileCollectionHost: AnyObject {
    func handleKey(_ key: FileViewKey) -> Bool
    func focusChanged()
}

/// Icons' and Gallery's collection view: the file views' keys go to their controller, and focus, or the window
/// becoming key or not, redraws the selection's emphasis. Each adds its own moves (`move(for:extend:)`), clicks,
/// menus and drags.
class FileCollectionView: NSCollectionView {
    weak var host: (any FileCollectionHost)?
    let copies: CopyProviders
    private var windowObservers: [NSObjectProtocol] = []

    init(copies: CopyProviders) {
        self.copies = copies
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEmphasized: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// Moves the selection for an arrow (without ⌘ or ⌃), Home or End: true when `keyCode` was one this view moves by.
    func move(for keyCode: UInt16, plain: Bool, extend: Bool) -> Bool { false }

    override func keyDown(with event: NSEvent) {
        guard let host else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if move(for: event.keyCode, plain: mods.isDisjoint(with: [.command, .control]), extend: mods.contains(.shift)) { return }
        if let key = FileViewKey.from(event) {
            if case .type = key {
                if host.handleKey(key) { return }
            } else {
                if !host.handleKey(key) { super.keyDown(with: event) }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        host?.focusChanged()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.host?.focusChanged() } }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.host?.focusChanged() }
            })
        }
    }
}

/// Tells a file view's delegate its selection: once after a run of changes made together, and only when it differs
/// from what was told last; or at once, when a menu is about to be built for it.
final class SelectionReports {
    private var pending = false
    private var last: [URL] = []
    private let selection: () -> [URL]
    private let tell: ([URL]) -> Void

    init(selection: @escaping () -> [URL], tell: @escaping ([URL]) -> Void) {
        self.selection = selection
        self.tell = tell
    }

    func soon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                let urls = self.selection()
                guard urls != self.last else { return }
                self.last = urls
                self.tell(urls)
            }
        }
    }

    func now() {
        last = selection()
        tell(last)
    }
}

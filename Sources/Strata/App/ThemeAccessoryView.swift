import AppKit

/// Color the native accessory's padding as well as its content, without changing AppKit's spacing or controls.
package final class ThemeAccessoryView: NSView, ColorThemeUpdating {
    private let paddingCanvas = ThemeSurfaceView()

    package init(role: ThemeSurfaceRole = .content) {
        super.init(frame: .zero)
        paddingCanvas.role = role
        paddingCanvas.ignoresMouse = true
        paddingCanvas.autoresizingMask = [.width, .height]
        ThemeStyle.bind(self, to: role)
        updateColorTheme()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package func updateColorTheme() {
        paddingCanvas.isHidden = !ThemeStyle.colorsSurfaces
        paddingCanvas.needsDisplay = true
    }

    package override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        paddingCanvas.removeFromSuperview()
        guard let parent = superview else { return }
        paddingCanvas.frame = parent.bounds
        parent.addSubview(paddingCanvas, positioned: .below, relativeTo: self)
    }
}

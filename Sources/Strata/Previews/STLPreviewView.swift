import AppKit
import StrataTheme
import WebKit

package final class STLPreviewView: WebPreviewView {
    private let url: URL
    private var document: STLDocument?
    private var colors: [[Double]]?

    package init(url: URL) {
        self.url = url
        super.init(page: PreviewWebPage(openLink: { _ in }))
        page.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(page)
        NSLayoutConstraint.activate(page.fillingConstraints(in: contentView))
        open()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { return nil }

    package override var isOpen: Bool { document != nil }

    package override func open() {
        let url = url
        load({ try await STLDocument.open(url) }, apply: { [weak self] document in
            guard let self, !stopped else { return }
            self.document = document
            showPage()
        })
    }

    package override func showPage() {
        guard !stopped, let document else { return }
        self.document = nil
        let colors = themeColors()
        self.colors = colors
        let settings = STLDocument.Settings(background: colors[0], color: colors[1], foreground: colors[2],
            triangles: String(localized: "Triangles", comment: "STL mesh triangle count"),
            bounds: String(localized: "Bounds (file units)", comment: "STL dimensions; the format does not specify millimeters or other units"),
            reset: String(localized: "Reset"), help: String(localized: "Drag to rotate; scroll to zoom."),
            large: String(localized: "This model is too large to preview."), unavailable: String(localized: "No Preview Available"))
        page.show({ try await document.page(settings: settings) }, failed: { [weak self] _ in self?.showFailure() })
        footer.show(["STL"])
    }

    private func showFailure() { showMessage(symbol: "cube.transparent", String(localized: "No Preview Available")) }

    package override func layout() {
        super.layout()
        let current = themeColors()
        guard let webView, colors != current else { return }
        colors = current
        webView.callAsyncJavaScript("globalThis.StrataSTL?.theme(background, color, foreground)",
            arguments: ["background": current[0], "color": current[1], "foreground": current[2]],
            in: nil, in: .defaultClient, completionHandler: nil)
    }

    private func themeColors() -> [[Double]] {
        var result: [[Double]] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = [ThemeStyle.surface(.preview), ThemeStyle.accent, NSColor.labelColor].map { color in
                guard let rgb = color.usingColorSpace(.sRGB) else { return [0.5, 0.5, 0.5] }
                return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
            }
        }
        return result
    }
}

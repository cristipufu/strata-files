import AppKit
import StrataTheme
import WebKit

package final class ModelPreviewView: WebPreviewView {
    private let url: URL
    private let format: ModelDocument.Format
    private var document: ModelDocument?
    private var colors: [[Double]]?

    package init(url: URL, format: ModelDocument.Format = .stl) {
        self.url = url
        self.format = format
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
        let url = url, format = format
        load({ try await ModelDocument.open(url, format: format) }, apply: { [weak self] document in
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
        let settings = ModelDocument.Settings(background: colors[0], color: colors[1], foreground: colors[2],
            triangles: String(localized: "Triangles", comment: "3D mesh triangle count"),
            bounds: String(localized: "Bounds (file units)", comment: "3D model dimensions; STL does not declare a unit of measurement"),
            reset: String(localized: "Reset"), help: String(localized: "Drag to rotate; scroll to zoom."),
            large: String(localized: "This model is too large to preview."), unavailable: String(localized: "No Preview Available"),
            format: format.label)
        page.show({ try await document.page(settings: settings) }, failed: { [weak self] _ in self?.showFailure() })
        footer.show([format.label])
    }

    private func showFailure() { showMessage(symbol: "cube.transparent", String(localized: "No Preview Available")) }

    package override func layout() {
        super.layout()
        let current = themeColors()
        guard let webView, colors != current else { return }
        colors = current
        webView.callAsyncJavaScript("globalThis.StrataModel?.theme(background, color, foreground)",
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

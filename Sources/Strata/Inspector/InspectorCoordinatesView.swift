import AppKit

final class InspectorCoordinatesView: NSStackView {
    let location: MediaLocation

    init(location: MediaLocation, clipboard: Clipboard, open: @escaping (URL) -> Void) {
        self.location = location
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 4
        addArrangedSubview(InspectorRows.text(location.coordinates))
        let actions = NSStackView()
        actions.spacing = 10
        actions.addArrangedSubview(LinkButton(String(localized: "Copy Coordinates"), font: .systemFont(ofSize: 11)) {
            clipboard.copyText(location.coordinates)
        })
        actions.addArrangedSubview(LinkButton(String(localized: "Open in Maps"), font: .systemFont(ofSize: 11)) {
            if let url = location.mapsURL { open(url) }
        })
        addArrangedSubview(actions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }
}

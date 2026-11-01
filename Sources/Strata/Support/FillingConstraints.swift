import AppKit

package extension NSView {
    /// The constraints that make this view fill `other`, edge to edge.
    func fillingConstraints(in other: NSView) -> [NSLayoutConstraint] {
        [
            leadingAnchor.constraint(equalTo: other.leadingAnchor),
            trailingAnchor.constraint(equalTo: other.trailingAnchor),
            topAnchor.constraint(equalTo: other.topAnchor),
            bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ]
    }
}

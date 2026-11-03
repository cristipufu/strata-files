import Foundation

nonisolated package enum ResourceBundle {
    package struct Missing: Error { package let name: String }

    // SwiftPM's generated accessor can trap and can find checkout resources that weren't packaged in an app.
    package static func named(_ name: String, in host: Bundle, linkedTo owner: Bundle) throws -> Bundle {
        let roots = host.bundleURL.pathExtension.lowercased() == "app"
            ? [host.resourceURL]
            : [host.resourceURL, host.bundleURL, owner.resourceURL, owner.bundleURL,
               owner.bundleURL.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(name + ".bundle")) { return bundle }
        }
        throw Missing(name: name)
    }
}

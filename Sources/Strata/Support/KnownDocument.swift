import Foundation
import UniformTypeIdentifiers

/// Files macOS has no type for and Strata knows: OneNote's, which even OneNote for Mac doesn't declare. Each has a name
/// for its Kind and a symbol its icon's page is marked with.
nonisolated package enum KnownDocument {
    package struct Kind: Sendable {
        package let name: String
        package let symbol: String
    }

    /// Only for an item whose own type no app declares: one that declares it gives it its own name and icon, and a
    /// folder, a link or an alias has a type of its own. An app that opens just the extension, with no type, doesn't
    /// count: macOS can't tell it from one that opens any document, and OneNote for Mac opens neither. The type is
    /// asked for only for an extension Strata knows.
    package static func kind(extension ext: String, type: @autoclosure () -> UTType?) -> Kind? {
        kinds[ext.lowercased()].flatMap { type()?.isDynamic == true ? $0 : nil }
    }

    private static let kinds = [
        "one": Kind(name: String(localized: "OneNote section", comment: "Kind of file"), symbol: "book.closed.fill"),
        "onepkg": Kind(name: String(localized: "OneNote notebook package", comment: "Kind of file"),
                       symbol: "books.vertical.fill"),
        "onetoc2": Kind(name: String(localized: "OneNote table of contents", comment: "Kind of file"),
                        symbol: "list.bullet"),
    ]
}

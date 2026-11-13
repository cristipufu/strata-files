import Foundation

/// The folders an index leaves out, with everything in them. Whatever needs to know whether a path is left out asks
/// here, so there is one rule: a path matches by whole components and without regard to letter case, since the usual
/// disk has none. "…/IR" holds "…/ir/new.txt", and neither "…/IR2" nor "…/IR.txt".
nonisolated package struct IndexExcludedFolders: Sendable, ExpressibleByArrayLiteral {
    /// The folders as they were given, without trailing slashes.
    package private(set) var paths: Set<String> = []
    /// The folders as they are compared: lowercased and in composed form.
    private var folded: Set<String> = []
    /// How long the folded folders are. A path is checked in one pass over its bytes, and compared with the folders
    /// only where one of them could end, so the cost of a check does not grow with the list.
    private var lengths: Set<Int> = []
    /// How many slashes the deepest folder has: no path is compared further down than that.
    private var deepest = 0

    package init() {}

    package init(_ folders: some Sequence<String>) {
        for folder in folders { insert(folder) }
    }

    package init(arrayLiteral folders: String...) {
        self.init(folders)
    }

    package var isEmpty: Bool { paths.isEmpty }

    /// Adds `folder`. A relative path names no folder and is ignored.
    package mutating func insert(_ folder: String) {
        let folder = Self.withoutTrailingSlashes(folder)
        guard folder.utf8.first == Self.slash else { return }
        let key = Self.folded(folder)
        paths.insert(folder)
        folded.insert(key)
        lengths.insert(key.utf8.count)
        deepest = max(deepest, key.utf8.count { $0 == Self.slash })
    }

    /// Whether `path` is one of the folders.
    package func contains(_ path: String) -> Bool {
        !folded.isEmpty && folded.contains(Self.folded(Self.withoutTrailingSlashes(path)))
    }

    /// Whether `path` is one of the folders or inside one.
    package func covers(_ path: String) -> Bool {
        guard !folded.isEmpty else { return false }
        if folded.contains("/") { return path.utf8.first == Self.slash }
        var length = 0
        for byte in path.utf8 {
            // Outside ASCII the two cases of a letter can differ in length, so such a path is compared folded whole.
            if byte >= 0x80 { return coversFolded(Self.folded(path)) }
            if byte == Self.slash, length > 0, isFolder(path, upTo: length) { return true }
            length += 1
        }
        return isFolder(path, upTo: length)
    }

    /// Whether every folder here is one of `other`'s.
    package func isSubset(of other: IndexExcludedFolders) -> Bool {
        folded.isSubset(of: other.folded)
    }

    private static let slash = UInt8(ascii: "/")

    /// Whether the first `length` bytes of `path`, all ASCII, spell one of the folders.
    private func isFolder(_ path: String, upTo length: Int) -> Bool {
        guard lengths.contains(length) else { return false }
        return folded.contains(String(decoding: path.utf8.prefix(length), as: UTF8.self).lowercased())
    }

    /// Whether `path`, folded, is one of the folders or has one above it. A folder ends at a slash as a byte: taken
    /// as a character, a slash runs together with a combining mark that follows it.
    private func coversFolded(_ path: String) -> Bool {
        let utf8 = path.utf8
        guard utf8.first == Self.slash else { return false }
        var slashes = 1
        var index = utf8.index(after: utf8.startIndex)
        while index < utf8.endIndex {
            if utf8[index] == Self.slash {
                if folded.contains(String(decoding: utf8[..<index], as: UTF8.self)) { return true }
                slashes += 1
                if slashes > deepest { return false }
            }
            index = utf8.index(after: index)
        }
        return folded.contains(path)
    }

    /// A folder's name in composed form, so its length in bytes is that of any plain spelling equal to it.
    private static func folded(_ path: String) -> String {
        path.lowercased().precomposedStringWithCanonicalMapping
    }

    /// `path` without the slashes that end it; the root keeps its own.
    package static func withoutTrailingSlashes(_ path: String) -> String {
        let utf8 = path.utf8
        var length = utf8.count
        while length > 1, utf8[utf8.index(utf8.startIndex, offsetBy: length - 1)] == slash { length -= 1 }
        return length == utf8.count ? path : String(decoding: utf8.prefix(length), as: UTF8.self)
    }
}

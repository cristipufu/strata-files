import Foundation

extension TestTree {
    /// ExFAT may create AppleDouble files even for an empty item's metadata. Keep every archive-owned name and
    /// ignore only additional, structurally valid metadata files with a partner in this same fixture.
    static func archiveListing(of folder: URL, keeping expected: [String]) -> [String] {
        let listing = listing(of: folder), owned = Set(expected), names = Set(listing)
        return listing.filter { name in
            guard !owned.contains(name), !name.hasSuffix("/"), !name.contains(" -> ") else { return true }
            let url = folder.appending(path: name), leaf = url.lastPathComponent
            guard leaf.hasPrefix("._") else { return true }
            let parent = (name as NSString).deletingLastPathComponent
            let partner = (parent.isEmpty ? "" : parent + "/") + leaf.dropFirst(2)
            guard names.contains(partner) || names.contains(partner + "/"),
                  let data = try? Data(contentsOf: url), data.count >= 26,
                  number(data, at: 0, count: 4) == 0x0005_1607,
                  number(data, at: 4, count: 4) == 0x0002_0000 else { return true }
            let count = number(data, at: 24, count: 2)
            guard count > 0, count <= (data.count - 26) / 12 else { return true }
            for entry in 0..<count {
                let offset = number(data, at: 30 + entry * 12, count: 4)
                let length = number(data, at: 34 + entry * 12, count: 4)
                guard offset >= 26 + count * 12, offset <= data.count, length <= data.count - offset else { return true }
            }
            return false
        }
    }

    private static func number(_ data: Data, at offset: Int, count: Int) -> Int {
        data[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
    }
}

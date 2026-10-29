import Foundation

/// The archive families Strata recognizes by name: the zip family, whose preview shows its size on disk and whose
/// `__MACOSX` folder Expand drops, and the formats `tar` reads.
nonisolated package enum ArchiveKind: Sendable {
    case zip
    case tar

    package init?(fileName: String) {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if Self.zipExtensions.contains(ext) {
            self = .zip
        } else if Self.tarExtensions.contains(ext) || Self.compressedTarSuffixes.contains(where: name.hasSuffix) {
            self = .tar
        } else {
            return nil
        }
    }

    private static let zipExtensions: Set<String> = ["cbz", "zip", "jar", "war", "ear", "aar", "apk", "aab", "ipa", "nupkg", "vsix", "whl", "xpi"]
    private static let tarExtensions: Set<String> = ["cbr", "cb7", "cbt", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "7z", "rar", "cpio", "xar", "iso"]
    private static let compressedTarSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"]
}

/// One file or folder inside an archive. Folders implied by deeper paths are created too.
nonisolated package final class ArchiveNode {
    package let name: String
    package let isDirectory: Bool
    package var size: Int64
    package var modified: Date?
    package var children: [ArchiveNode] = []
    /// Subfolders by name, only while the tree is being built.
    fileprivate var folders: [String: ArchiveNode] = [:]

    package init(name: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// The subfolder called `name`, created if needed.
    fileprivate func folder(_ name: String, created: inout Int) -> ArchiveNode {
        if let existing = folders[name] { return existing }
        let node = ArchiveNode(name: name, isDirectory: true)
        children.append(node)
        folders[name] = node
        created += 1
        return node
    }
}

nonisolated package struct ArchiveListing: Sendable {
    package let root: Handoff<ArchiveNode>
    package let files: Int
    package let folders: Int
    package let uncompressed: Int64
    package let compressed: Int64?
    /// Why the listing is incomplete, if it is.
    package let note: String?

    package init(root: Handoff<ArchiveNode>, files: Int, folders: Int, uncompressed: Int64, compressed: Int64?, note: String?) {
        self.root = root
        self.files = files
        self.folders = folders
        self.uncompressed = uncompressed
        self.compressed = compressed
        self.note = note
    }
}

nonisolated package enum ArchiveLister {
    package static let timeout: TimeInterval = 10
    private static let nodeLimit = 100_000

    /// Lists `url` in the archive service's sandboxed worker, as a tree. A link to an archive lists the archive.
    @concurrent
    package static func list(_ url: URL, kind: ArchiveKind, timeout: TimeInterval = timeout) async throws -> ArchiveListing {
        let source: PreviewArchiveSource, listed: PreviewArchiveListing
        do {
            source = try PreviewArchiveSource(url.resolvingSymlinksInPath())
            listed = try await PreviewArchiveReader.list(source, timeout: timeout)
        } catch let error as POSIXError where error.code == .ESTALE {
            // The archive changed before it could be pinned, as one still downloading can.
            throw PreviewError.message(reason(.unreadable, named: url.lastPathComponent), symbol: "archivebox")
        } catch let error as PreviewArchiveError {
            throw PreviewError.message(reason(error, named: url.lastPathComponent), symbol: "archivebox")
        }
        try Task.checkCancellation()
        return try tree(listed, compressed: kind == .zip ? source.size : nil, named: url.lastPathComponent)
    }

    /// Why an archive called `name` can't be read without its password: Strata's listings never ask for one.
    package static func passwordProtected(_ name: String) -> String {
        String(localized: "“\(name)” is password-protected. Open it with Archive Utility to enter the password.")
    }

    /// The listing of the archive called `name` as a tree. A listing cut short shows what it read, and says why: past
    /// its limits (time, memory, entries) it shows the first part, and a password, an unsafe entry or a failed read says
    /// so.
    package static func tree(_ listed: PreviewArchiveListing, compressed: Int64?, named name: String) throws -> ArchiveListing {
        if listed.records.isEmpty {
            let message = switch listed.end {
            case .complete: String(localized: "This archive is empty.")
            case .moreEntries: reason(.limit, named: name)
            case .stopped(let error): reason(error, named: name)
            }
            throw PreviewError.message(message, symbol: "archivebox")
        }
        let root = ArchiveNode(name: "", isDirectory: true)
        var files = 0, folders = 0, shown = 0
        var bytes: Int64 = 0
        for record in listed.records {
            try Task.checkCancellation()
            // Entries also create the folders they imply: bound the tree's nodes.
            guard files + folders + record.path.count <= nodeLimit, let last = record.path.last else { break }
            shown += 1
            var parent = root
            for component in record.path.dropLast() { parent = parent.folder(component, created: &folders) }
            if record.kind == 2 {
                parent.folder(last, created: &folders).modified = record.modified
            } else {
                parent.children.append(ArchiveNode(name: last, isDirectory: false, size: record.size, modified: record.modified))
                files += 1
                // Sizes an archive claims can overflow a total.
                bytes = bytes.addingReportingOverflow(record.size).overflow ? .max : bytes + record.size
            }
        }
        sortAndTotal(root)
        let partial = String(localized: "Showing first \(shown.formatted())",
                             comment: "Preview footer note: only the first part is shown (a count or a size)")
        let cut = shown < listed.records.count
        let note: String? = switch listed.end {
        case .moreEntries, .stopped(.limit): partial
        case .stopped(let error): cut ? partial + " · " + reason(error, named: name) : reason(error, named: name)
        case .complete: cut ? partial : nil
        }
        return ArchiveListing(root: Handoff(value: root), files: files, folders: folders, uncompressed: bytes,
                              compressed: compressed, note: note)
    }

    private static func reason(_ error: PreviewArchiveError, named name: String) -> String {
        switch error {
        case .password: passwordProtected(name)
        case .limit, .unsafe, .encryption: error.localizedDescription
        case .unreadable, .needsExtraction: String(localized: "This archive couldn’t be read.")
        }
    }

    /// Folders first, then names in Finder order; folder sizes are the sum of their contents.
    @discardableResult
    private static func sortAndTotal(_ node: ArchiveNode) -> Int64 {
        guard node.isDirectory else { return node.size }
        node.folders = [:]
        node.size = node.children.reduce(0) { total, child in
            let (sum, overflow) = total.addingReportingOverflow(sortAndTotal(child))
            return overflow ? .max : sum
        }
        node.children.sort { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return node.size
    }
}

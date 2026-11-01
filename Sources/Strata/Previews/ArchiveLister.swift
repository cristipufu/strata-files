import StrataArchives
import Foundation
import UniformTypeIdentifiers

/// One file or folder inside an archive. Folders implied by deeper paths are created too.
nonisolated package final class ArchiveNode {
    package let name: String
    package let isDirectory: Bool
    package var size: Int64
    package var modified: Date?
    package var children: [ArchiveNode] = []
    /// Subfolders by name, only while the tree is being built.
    fileprivate var folders: [String: ArchiveNode] = [:]

    /// What its name says it is: nothing in an archive declares a type.
    package var contentType: UTType {
        isDirectory ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

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
        let source: ArchiveSource, listed: ArchiveReadListing
        do {
            source = try ArchiveSource(url.resolvingSymlinksInPath())
            listed = try await ArchiveReader.list(source, timeout: timeout)
        } catch let error as POSIXError where error.code == .ESTALE {
            // The archive changed before it could be pinned, as one still downloading can.
            throw PreviewError.message(reason(.unreadable, named: url.lastPathComponent), symbol: "archivebox")
        } catch let error as ArchiveReadError {
            throw PreviewError.message(reason(error, named: url.lastPathComponent), symbol: "archivebox")
        }
        try Task.checkCancellation()
        return try tree(listed, compressed: kind == .zip ? source.size : nil, named: url.lastPathComponent)
    }

    /// The listing of the archive called `name` as a tree. A listing cut short shows what it read, and says why: past
    /// its limits (time, memory, entries) it shows the first part, and a password, an unsafe entry or a failed read says
    /// so.
    package static func tree(_ listed: ArchiveReadListing, compressed: Int64?, named name: String) throws -> ArchiveListing {
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

    private static func reason(_ error: ArchiveReadError, named name: String) -> String {
        switch error {
        case .password: ArchiveReadError.passwordProtected(name)
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

import AppKit
import StrataPreviews

/// A preview row is either an existing file or an archive member. Archive paths never masquerade as local URLs.
@MainActor final class PreviewItem {
    enum Source {
        case file(FileEntry)
        case member(ArchiveNode, path: [String])
    }

    private(set) var source: Source
    weak var parent: PreviewItem?
    var children: [PreviewItem]?
    /// Where it comes in the order of the OneNote notebook its folder or archive holds.
    var notebookPosition: Int?

    init(_ source: Source, parent: PreviewItem? = nil) {
        self.source = source
        self.parent = parent
    }

    var entry: FileEntry? {
        if case .file(let entry) = source { return entry }
        return nil
    }

    var name: String {
        switch source {
        case .file(let entry): entry.displayName
        case .member(let node, _): node.name
        }
    }

    var isDirectory: Bool {
        switch source {
        case .file(let entry): entry.isFolder && !entry.isSymlink
        case .member(let node, _): node.isDirectory
        }
    }

    var size: Int64? {
        switch source {
        case .file(let entry): entry.size
        case .member(let node, _): node.isDirectory ? nil : node.size
        }
    }

    var modified: Date? {
        switch source {
        case .file(let entry): entry.modified
        case .member(let node, _): node.modified
        }
    }

    var kind: String {
        switch source {
        case .file(let entry): return entry.kind
        case .member(let node, _):
            let type = node.contentType
            return FileEntry.kind(extension: (node.name as NSString).pathExtension, isDirectory: node.isDirectory,
                                  isPackage: false, size: size, system: type.localizedDescription, type: type)
        }
    }

    func icon(_ thumbnails: FileThumbnails) -> NSImage {
        switch source {
        case .file(let entry): thumbnails.icon(for: entry)
        case .member(let node, _): IconCache.shared.icon(forType: node.contentType)
        }
    }

    func fetched(_ entry: FileEntry) {
        guard case .file(let old) = source, old.url.path.utf8.elementsEqual(entry.url.path.utf8) else { return }
        source = .file(entry)
    }

    func archiveChildren() -> [PreviewItem]? {
        guard case .member(let node, let path) = source else { return nil }
        return node.children.map { PreviewItem(.member($0, path: path + [$0.name]), parent: self) }
    }
}

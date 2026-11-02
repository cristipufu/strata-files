import Foundation
import StrataFiles
import StrataModel

nonisolated struct InspectorSelectionSizes: Sendable {
    struct Folder: Sendable {
        let size: FolderSize?
        let unmeasured: Bool
    }

    typealias Reader = @Sendable ([FileEntry], [URL: Folder], CopyProviders) async -> InspectorSelectionSizes?

    var logical: Int64 = 0
    var allocated: Int64?
    var allocationComplete = true
    var supportsAllocation = true
    var pending = false
    var unmeasured = 0
    var folders = 0

    @concurrent static func read(_ items: [FileEntry], folders facts: [URL: Folder], copies: CopyProviders) async -> Self? {
        var result = Self(), allocation: Int64 = 0
        var allocationKnown = true
        for (index, item) in items.enumerated() {
            if index & 63 == 0, Task.isCancelled { return nil }
            if item.isFolder { result.folders += 1 }
            let folder = facts[item.url]
            if let bytes = item.isDirectory ? folder?.size?.bytes : item.size {
                result.logical = result.logical.saturatingAdd(bytes)
            } else if folder?.unmeasured == true { result.unmeasured += 1 }
            else { result.pending = true }

            let local = !copies.contains(item.url) && ArchiveCache.apparentURL(item.url) == nil
            if !local { result.supportsAllocation = false }
            if folder?.size?.allocationComplete == false { result.allocationComplete = false }
            let diskBytes = item.isDirectory && !item.isSymlink ? folder?.size?.allocatedBytes : item.allocatedSize
            if local, let diskBytes { allocation = allocation.saturatingAdd(diskBytes) }
            else { allocationKnown = false }
        }
        result.allocated = allocationKnown ? allocation : nil
        return result
    }
}

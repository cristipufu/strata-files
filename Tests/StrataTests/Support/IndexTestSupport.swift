@testable import StrataIndex

extension IndexStore.Storage {
    nonisolated mutating func setTestAllocation(_ bytes: Int64?, of id: Int32) {
        var bytesDelta: Int64 = 0, allocatedDelta: Int64 = 0, unknownChanged = false
        let i = Int(id), parent = self.parent[i]
        updateFile(id, size: size[i], allocatedSize: bytes, mtime: mtime[i],
                   bytesDelta: &bytesDelta, allocatedDelta: &allocatedDelta, unknownChanged: &unknownChanged)
        propagateTotals(from: parent, bytes: bytesDelta, files: 0, allocatedBytes: allocatedDelta)
        if unknownChanged { refreshAllocationKnown(from: parent) }
    }
}

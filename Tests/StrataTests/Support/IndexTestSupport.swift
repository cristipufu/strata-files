import CryptoKit
import Foundation
@testable import Strata
@testable import StrataFiles
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch

extension FileIndex {
    /// An index over `tree`'s own `home` and `Apps` folders, kept in its `state` folder and following `preferences`:
    /// what lies in that home folder can be excluded, as in your own. With a `key` it can save itself; `makeWorker`
    /// gives it workers of the test's own, such as ones that watch no file events.
    @MainActor static func over(_ tree: TestTree, following preferences: Prefs,
                                realPaths: @escaping @Sendable ([URL]) async -> [String] = realPathsHoweverLongTheyTake,
                                key: SymmetricKey? = nil,
                                mountedVolumes: @escaping IndexMountedVolumes.Reader = IndexMountedVolumes.inside,
                                makeWorker: @escaping @MainActor () -> IndexWorker = { IndexWorker() }) -> FileIndex {
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("Caches"), key: key)
        let copies = CopyProviders([], remoteCopies: RemoteCopyStore(root: tree.url("Servers"), server: { _ in nil }),
                                   containerCopies: ContainerCopyStore(root: tree.url("Containers")),
                                   clipboardRoot: tree.url("Clipboard"))
        return FileIndex(storage: storage, copies: copies, preferences: preferences,
                         folders: (home: tree.url("home"), applications: tree.url("Apps")), realPaths: realPaths,
                         mountedVolumes: mountedVolumes, makeWorker: makeWorker)
    }

    /// Where folders really are, waited for: a test's own disk answers, and none should fail because a busy machine
    /// was slow to.
    nonisolated static let realPathsHoweverLongTheyTake: @Sendable ([URL]) async -> [String] = {
        await IndexExclusions.realPaths($0, within: .seconds(3600))
    }
}

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

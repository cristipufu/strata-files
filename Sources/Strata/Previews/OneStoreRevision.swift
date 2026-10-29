import Foundation

/// The GUIDs a global identification table gives the CompactIDs that follow it.
nonisolated struct GlobalIDTable: Sendable {
    fileprivate var guids: [UInt32: StoredGUID] = [:]

    func identity(_ compact: UInt32) throws -> ExtendedGUID {
        guard let guid = guids[compact >> 8] else {
            // Zero with no entry 0 to name stands for no object: real sections write it in rich text.
            guard compact == 0 else { throw OneStoreError.malformed }
            return .zero
        }
        return ExtendedGUID(guid: guid, n: compact & 0xFF)
    }
}

/// An object of a revision: a property set, or a file the section holds.
nonisolated struct StoredObject: Sendable {
    enum Content: Sendable {
        case properties(FileChunk, GlobalIDTable)
        /// Its FileDataReference: "<ifndf>{guid}" names data inside the file; other forms name files elsewhere.
        case fileData(String)
    }

    let jcid: UInt32
    let content: Content
}

/// The objects and root objects a revision resolves to, with those of the revisions it depends on.
nonisolated struct Revision: Sendable {
    var objects: [ExtendedGUID: StoredObject] = [:]
    var roots: [UInt32: ExtendedGUID] = [:]

    /// Declares or revises `object`. No object is the null identity, which empty references name.
    mutating func declare(_ id: ExtendedGUID, _ object: StoredObject) {
        guard id != .zero else { return }
        objects[id] = object
    }
}

nonisolated struct StoreLayout: Sendable {
    let root: ExtendedGUID
    let spaces: [ExtendedGUID: FileChunk]
    let fileData: [StoredGUID: FileChunk]
}

nonisolated enum RootRole {
    static let content: UInt32 = 1
    static let metadata: UInt32 = 2
}

/// The object spaces and revisions of a section. Nodes only notebooks (`.onetoc2`) use are left to a notebook reader.
nonisolated extension OneStore {
    private enum NodeID {
        static let objectSpaceManifestRoot: UInt16 = 0x004
        static let objectSpaceManifestListReference: UInt16 = 0x008
        static let revisionManifestListReference: UInt16 = 0x010
        static let revisionManifestEnd: UInt16 = 0x01C
        static let revisionManifestStart6: UInt16 = 0x01E
        static let revisionManifestStart7: UInt16 = 0x01F
        static let globalIDTableStart2: UInt16 = 0x022
        static let globalIDTableEntry: UInt16 = 0x024
        static let rootObjectReference3: UInt16 = 0x05A
        static let revisionRoleDeclaration: UInt16 = 0x05C
        static let revisionRoleAndContextDeclaration: UInt16 = 0x05D
        static let objectDeclarationFileData3: UInt16 = 0x072
        static let objectDeclarationFileData3Large: UInt16 = 0x073
        static let objectDataEncryptionKey: UInt16 = 0x07C
        static let fileDataStoreListReference: UInt16 = 0x090
        static let fileDataStoreObjectReference: UInt16 = 0x094
        static let objectDeclaration2: UInt16 = 0x0A4
        static let objectDeclaration2Large: UInt16 = 0x0A5
        static let objectGroupListReference: UInt16 = 0x0B0
        static let readOnlyObjectDeclaration2: UInt16 = 0x0C4
        static let readOnlyObjectDeclaration2Large: UInt16 = 0x0C5
        static let manifestBounds: Set<UInt16> = [revisionManifestEnd, revisionManifestStart6, revisionManifestStart7]
        static let propertySetDeclarations: Set<UInt16> = [objectDeclaration2, objectDeclaration2Large,
                                                           readOnlyObjectDeclaration2, readOnlyObjectDeclaration2Large]
    }

    /// The role that labels a revision as the active view of its object space.
    private static let activeView: UInt32 = 1

    /// The object spaces the file holds, which one is its root, and the file data it embeds.
    func layout() throws -> StoreLayout {
        try Self.reading { try readLayout() }
    }

    private func readLayout() throws -> StoreLayout {
        var root: ExtendedGUID?, spaces: [ExtendedGUID: FileChunk] = [:], fileData: [StoredGUID: FileChunk] = [:]
        for node in try nodes(in: self.root) {
            var cursor = ByteCursor(node.data)
            switch node.id {
            case NodeID.objectSpaceManifestRoot:
                root = try ExtendedGUID(&cursor)
            case NodeID.objectSpaceManifestListReference:
                guard let list = node.reference else { throw OneStoreError.malformed }
                spaces[try ExtendedGUID(&cursor)] = list
            case NodeID.fileDataStoreListReference:
                guard let list = node.reference else { throw OneStoreError.malformed }
                for entry in try nodes(in: list) where entry.id == NodeID.fileDataStoreObjectReference {
                    var reference = ByteCursor(entry.data)
                    guard let block = entry.reference else { throw OneStoreError.malformed }
                    fileData[try StoredGUID(&reference)] = block
                }
            default:
                continue
            }
        }
        guard let root, spaces[root] != nil else { throw OneStoreError.malformed }
        return StoreLayout(root: root, spaces: spaces, fileData: fileData)
    }

    /// The revision an object space shows: the one last labeled with the default context and the active-view role.
    /// Nil when it has none, as an object space only older page versions use.
    func liveRevision(of space: FileChunk) throws -> Revision? {
        try Self.reading { try readLiveRevision(of: space) }
    }

    private func readLiveRevision(of space: FileChunk) throws -> Revision? {
        // When an object space lists several revision manifest lists, all but the last are ignored.
        guard let list = try nodes(in: space).last(where: { $0.id == NodeID.revisionManifestListReference })?.reference
        else { throw OneStoreError.malformed }
        let (manifests, live) = try revisionManifests(in: list)
        guard let live else { return nil }
        return try resolve(live, in: manifests)
    }

    private struct Manifest {
        let dependency: ExtendedGUID
        let nodes: ArraySlice<FileNode>
        let encrypted: Bool
    }

    private func revisionManifests(in list: FileChunk) throws -> ([ExtendedGUID: Manifest], live: ExtendedGUID?) {
        let nodes = try self.nodes(in: list)
        var manifests: [ExtendedGUID: Manifest] = [:], live: ExtendedGUID?, index = nodes.startIndex
        while index < nodes.endIndex {
            let node = nodes[index]
            var cursor = ByteCursor(node.data)
            index += 1
            switch node.id {
            case NodeID.revisionManifestStart6, NodeID.revisionManifestStart7:
                let id = try ExtendedGUID(&cursor), dependency = try ExtendedGUID(&cursor)
                let role: UInt32 = try cursor.read(), encoding: UInt16 = try cursor.read()
                let context = node.id == NodeID.revisionManifestStart7 ? try ExtendedGUID(&cursor) : .zero
                // A manifest ends before the next one starts.
                guard let end = nodes[index...].firstIndex(where: { NodeID.manifestBounds.contains($0.id) }),
                      nodes[end].id == NodeID.revisionManifestEnd else { throw OneStoreError.malformed }
                manifests[id] = Manifest(dependency: dependency, nodes: nodes[index..<end], encrypted: encoding != 0)
                if role == Self.activeView, context == .zero { live = id }
                index = end + 1
            case NodeID.revisionRoleDeclaration, NodeID.revisionRoleAndContextDeclaration:
                let id = try ExtendedGUID(&cursor), role: UInt32 = try cursor.read()
                let context = node.id == NodeID.revisionRoleAndContextDeclaration ? try ExtendedGUID(&cursor) : .zero
                if role == Self.activeView, context == .zero { live = id }
            default:
                continue
            }
        }
        return (manifests, live)
    }

    /// The revision `id` names, with the revisions it depends on applied first: a dependency's objects and root objects
    /// are this revision's too, except where it declares its own.
    private func resolve(_ id: ExtendedGUID, in manifests: [ExtendedGUID: Manifest]) throws -> Revision {
        var chain: [Manifest] = [], next = id, seen: Set<ExtendedGUID> = []
        while next != .zero {
            guard seen.insert(next).inserted, let manifest = manifests[next] else { throw OneStoreError.malformed }
            guard chain.count < limits.dependencies else { throw OneStoreError.tooLarge }
            guard !manifest.encrypted else { throw OneStoreError.encrypted }
            chain.append(manifest)
            next = manifest.dependency
        }
        var revision = Revision()
        for manifest in chain.reversed() { try declare(manifest.nodes, into: &revision, inGroup: false) }
        return revision
    }

    /// Applies a revision manifest's nodes, or an object group's, in order: later declarations of an object revise it.
    private func declare(_ nodes: some Collection<FileNode>, into revision: inout Revision, inGroup: Bool) throws {
        var table = GlobalIDTable()
        for node in nodes {
            var cursor = ByteCursor(node.data)
            switch node.id {
            case NodeID.globalIDTableStart2:
                table = GlobalIDTable()
            case NodeID.globalIDTableEntry:
                let index: UInt32 = try cursor.read()
                guard index < 0xFF_FFFF else { throw OneStoreError.malformed }
                table.guids[index] = try StoredGUID(&cursor)
            case NodeID.objectGroupListReference:
                guard !inGroup, let group = node.reference else { throw OneStoreError.malformed }
                try declare(try self.nodes(in: group), into: &revision, inGroup: true)
            case _ where NodeID.propertySetDeclarations.contains(node.id):
                guard let chunk = node.reference else { throw OneStoreError.malformed }
                let id = try table.identity(try cursor.read()), jcid: UInt32 = try cursor.read()
                revision.declare(id, StoredObject(jcid: jcid, content: .properties(chunk, table)))
            case NodeID.objectDeclarationFileData3, NodeID.objectDeclarationFileData3Large:
                let id = try table.identity(try cursor.read()), jcid: UInt32 = try cursor.read()
                try cursor.skip(node.id == NodeID.objectDeclarationFileData3 ? 1 : 4)
                revision.declare(id, StoredObject(jcid: jcid, content: .fileData(try Self.string(&cursor))))
            case NodeID.rootObjectReference3:
                let id = try ExtendedGUID(&cursor)
                revision.roots[try cursor.read()] = id
            case NodeID.objectDataEncryptionKey:
                throw OneStoreError.encrypted
            default:
                continue
            }
        }
    }

    /// A StringInStorageBuffer: a count of UTF-16 code units, then the units.
    private static func string(_ cursor: inout ByteCursor) throws -> String {
        let count: UInt32 = try cursor.read()
        return String(decoding: try cursor.units(Int(count)), as: UTF16.self)
    }
}

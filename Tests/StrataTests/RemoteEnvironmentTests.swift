import AppKit
import Security
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct RemoteEnvironmentTests {
    nonisolated private final class Backend: RemoteBackend {
        private let closes = Mutex(0)
        var closeCount: Int { closes.withLock { $0 } }
        var isAlive: Bool { closeCount == 0 }
        func close() { closes.withLock { $0 += 1 } }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] { [] }
        func kind(of path: String) async throws -> RemoteItemKind? { nil }
        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw RemoteError.unknownServer }
        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw RemoteError.unknownServer }
        func makeFolder(_ path: String) async throws { throw RemoteError.unknownServer }
        func rename(_ path: String, to newPath: String) async throws { throw RemoteError.unknownServer }
        func remove(_ path: String) async throws { throw RemoteError.unknownServer }
    }

    nonisolated private final class Network: Sendable {
        let backend = Backend()
        let logins = Mutex<[(RemoteServer, String?)]>([])
        let deletions = Mutex<[String]>([])
        var connector: RemoteConnector {
            RemoteConnector { server, secret in
                self.logins.withLock { $0.append((server, secret)) }
                return self.backend
            }
        }
        func credentials(_ secret: String) -> RemoteKeychain {
            RemoteKeychain(access: KeychainAccess(copy: { _ in (errSecSuccess, Data(secret.utf8) as CFData) },
                add: { _ in errSecSuccess }, update: { _, _ in errSecSuccess }, delete: { query in
                    let account = (query as NSDictionary)[kSecAttrAccount] as? String ?? ""
                    self.deletions.withLock { $0.append(account) }
                    return errSecSuccess
                }))
        }
    }

    private final class Environment {
        let preferences: Prefs
        let network = Network()
        let remote: RemoteServices
        let services: BrowserServices

        init(_ tree: TestTree, folder: String, notifications: NotificationCenter, saved: [RemoteServer] = [],
             reader: DirectoryReader? = DirectoryReader { _, _, _ in [] }) throws {
            preferences = try Prefs.isolated()
            preferences.defaults.set(try JSONEncoder().encode(saved), forKey: "remoteServers")
            preferences.showIconPreviews = false
            remote = RemoteServices(preferences: preferences, credentials: network.credentials(folder),
                copyRoot: tree.url(folder + "/cache"), connector: network.connector, notifications: notifications)
            let storage = SecureStorage.Context(directory: tree.url(folder + "/state"), caches: tree.url(folder + "/state/Caches"), key: nil)
            let copies = CopyProviders(servers: remote.files, containers: .shared)
            services = BrowserServices.configured(
                transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: copies),
                                         copies: copies),
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: remote,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: reader)
        }
    }

    private func server(_ id: String = UUID().uuidString, name: String) -> RemoteServer {
        RemoteServer(id: id, kind: .s3, name: name, host: "fixture.invalid", bucket: "fixture",
                     region: "eu-west-1", accessKeyID: "FIXTUREKEY", pathStyle: false)
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    private func items(_ sidebar: SidebarViewController) throws -> [SidebarItem] {
        let outline = try #require(views(sidebar.view, of: SidebarOutlineView.self).first { $0.dataSource === sidebar })
        return (0..<sidebar.outlineView(outline, numberOfChildrenOfItem: nil)).flatMap { index -> [SidebarItem] in
            guard let section = sidebar.outlineView(outline, child: index, ofItem: nil) as? SidebarSection,
                  section.id == "servers" else { return [] }
            return section.items
        }
    }

    @Test func defaultWindowReadersUseTheirRemoteEnvironmentWithoutAnOverride() async throws {
        let tree = try TestTree("left/keep", "right/keep"), center = NotificationCenter()
        let a = server(name: "Left"), b = server(a.id, name: "Right")
        let left = try Environment(tree, folder: "left", notifications: center, saved: [a], reader: nil)
        let right = try Environment(tree, folder: "right", notifications: center, saved: [b], reader: nil)
        let lt = try left.remote.copies.prepare(a), rt = try right.remote.copies.prepare(b)
        let before = tree.snapshot()
        #expect(left.services.copies.contains(lt) && !left.services.copies.contains(rt))
        #expect(right.services.copies.contains(rt) && !right.services.copies.contains(lt))
        #expect(try await left.services.directories.load(lt, showHidden: false, applications: .standard).isEmpty)
        #expect(left.network.logins.withLock { $0.count } == 1)
        #expect(right.network.logins.withLock { $0.isEmpty })
        #expect(try await right.services.directories.load(rt, showHidden: false, applications: .standard).isEmpty)
        #expect(right.network.logins.withLock { $0.count } == 1)
        #expect(left.network.logins.withLock { $0.map(\.0) } == [a])
        #expect(right.network.logins.withLock { $0.map(\.0) } == [b])
        await left.remote.sessions.disconnect(a.id)
        await right.remote.sessions.disconnect(b.id)
        withExtendedLifetime((left, right)) {}
        #expect(tree.snapshot() == before)
    }

    @Test func sidebarsAndFolderTreesKeepTheirServerStoreStatusAndNotifications() throws {
        let tree = try TestTree("left/keep", "right/keep"), center = NotificationCenter()
        let a = server(name: "Left"), b = server(a.id, name: "Right")
        let left = try Environment(tree, folder: "left", notifications: center, saved: [a])
        let right = try Environment(tree, folder: "right", notifications: center, saved: [b])
        defer { withExtendedLifetime((left, right)) {} }
        let ls = SidebarViewController(services: left.services), rs = SidebarViewController(services: right.services)
        let before = tree.snapshot()
        #expect(try items(ls).map(\.title) == ["Left"])
        #expect(try items(rs).map(\.title) == ["Right"])
        let rightItem = try #require(items(rs).first)
        let lt = try #require(ls.children.compactMap { $0 as? FolderTreeController }.first)
        let rt = try #require(rs.children.compactMap { $0 as? FolderTreeController }.first)
        #expect(lt.currentRoots(hasContainers: false).filter { $0.kind == .server }.map(\.title) == ["Left"])
        #expect(rt.currentRoots(hasContainers: false).filter { $0.kind == .server }.map(\.title) == ["Right"])
        // Keep the ownership assertions within synchronous delivery. Other suites may legitimately refresh all
        // sidebars for mounted volumes or Trash changes while an asynchronous connection is pending.
        left.remote.status.changed(a.id, connected: true)
        #expect(try items(ls).first?.tint == .systemGreen)
        #expect(try items(rs).first === rightItem)
        #expect(rightItem.tint == nil && right.remote.status.connected.isEmpty)
        var renamed = a; renamed.name = "Renamed"
        try left.remote.servers.save(renamed)
        #expect(try items(ls).map(\.title) == ["Renamed"])
        #expect(try items(rs).first === rightItem)
        #expect(lt.currentRoots(hasContainers: false).filter { $0.kind == .server }.map(\.title) == ["Renamed"])
        ls.highlight(.folder(left.remote.copies.top(of: a.id)))
        let outline = try #require(views(ls.view, of: SidebarOutlineView.self).first { $0.dataSource === ls })
        #expect((outline.item(atRow: outline.selectedRow) as? SidebarItem)?.target == .server(a.id))
        left.remote.status.changed(a.id, connected: false)
        #expect(try items(ls).first?.tint == nil)
        #expect(try items(rs).first === rightItem)
        left.preferences.sidebarShowsTree = true
        let oldRoot = try #require(lt.currentRoots(hasContainers: false).first { $0.kind == .server })
        #expect(oldRoot.symbol == "externaldrive.connected.to.line.below")
        renamed.kind = .sftp
        try left.remote.servers.save(renamed)
        let newRoot = try #require(lt.currentRoots(hasContainers: false).first { $0.kind == .server })
        #expect(newRoot !== oldRoot && newRoot.symbol == "server.rack")
        #expect(tree.snapshot() == before)
    }

    @Test func serviceOwnersAreReleasedAfterTheirSidebarAndConnectionsFinish() async throws {
        let tree = try TestTree("left/keep"), center = NotificationCenter()
        let server = server(name: "Fixture")
        var environment: Environment? = try Environment(tree, folder: "left", notifications: center, saved: [server])
        weak let remote = environment?.remote
        weak let store = remote?.servers
        weak let sessions = remote?.sessions
        weak let status = remote?.status
        weak let connections = remote?.connections
        weak var sidebar: SidebarViewController?
        try autoreleasepool {
            let native = SidebarViewController(services: try #require(environment?.services))
            sidebar = native
            _ = native.view
        }
        #expect(sidebar == nil)
        _ = try await remote?.sessions.backend(for: server.id)
        await remote?.sessions.disconnect(server.id)
        let before = tree.snapshot()
        environment = nil
        #expect(remote == nil)
        #expect(store == nil)
        #expect(sessions == nil)
        #expect(status == nil)
        #expect(connections == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func browsingAndRemovalKeepMatchingIDsInSeparateEnvironments() async throws {
        let tree = try TestTree("left/keep", "right/keep"), center = NotificationCenter()
        let a = server(name: "Left"), b = server(a.id, name: "Right")
        let left = try Environment(tree, folder: "left", notifications: center, saved: [a])
        let right = try Environment(tree, folder: "right", notifications: center, saved: [b])
        defer { withExtendedLifetime((left, right)) {} }
        #expect(try await left.services.remoteBrowsing.open(a) == left.remote.copies.top(of: a.id))
        #expect(try await right.services.remoteBrowsing.open(b) == right.remote.copies.top(of: b.id))
        #expect(left.network.logins.withLock { $0.count == 1 && $0[0].0 == a && $0[0].1 == "left" })
        #expect(right.network.logins.withLock { $0.count == 1 && $0[0].0 == b && $0[0].1 == "right" })
        #expect(left.remote.status.connected == [a.id] && right.remote.status.connected == [b.id])
        let before = tree.snapshot()
        let removed = try #require(left.remote.remove(a))
        #expect(await removed.value)
        #expect(left.remote.servers.all.isEmpty && left.remote.status.connected.isEmpty)
        #expect(left.network.backend.closeCount == 1 && left.network.deletions.withLock { $0 } == [a.id])
        #expect(right.remote.servers.all == [b] && right.remote.status.connected == [b.id])
        #expect(right.network.backend.isAlive && right.network.deletions.withLock { $0.isEmpty })
        #expect(tree.snapshot() == before.filter { !$0.hasPrefix("left/cache/" + a.id + "/") })
        await right.remote.sessions.disconnect(b.id)
        #expect(tree.snapshot() == before.filter { !$0.hasPrefix("left/cache/" + a.id + "/") })
    }

    @Test func workspacePlansAndTooltipsUseTheirOwnServerPaths() throws {
        let tree = try TestTree("left/keep", "right/keep"), center = NotificationCenter()
        let a = server(name: "Left"), b = server(a.id, name: "Right")
        let left = try Environment(tree, folder: "left", notifications: center, saved: [a])
        let right = try Environment(tree, folder: "right", notifications: center, saved: [b])
        defer { withExtendedLifetime((left, right)) {} }
        let before = tree.snapshot()
        let path = left.remote.copies.top(of: a.id).path
        let workspace = Workspace(name: "Work", tabs: [[path]], modes: [[BrowserViewMode.gallery.rawValue]])
        let plan = left.services.workspaces.plan(workspace)
        #expect(plan.tabs.first?.first?.waiting == WaitingFolder(path: path, mode: BrowserViewMode.gallery.rawValue, server: a.id))
        #expect(plan.missing.isEmpty)
        #expect(right.services.workspaces.plan(workspace).missing == [path])
        #expect(left.services.workspaces.help(workspace) == "Left")
        #expect(right.services.workspaces.help(workspace) == a.id)
        #expect(left.network.logins.withLock { $0.isEmpty } && right.network.logins.withLock { $0.isEmpty })
        #expect(tree.snapshot() == before)
    }

    @Test func theWindowsNativeServerSheetConnectsThroughItsOwnEnvironment() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("left/keep", "right/keep"), center = NotificationCenter()
        let a = server(name: "Left"), b = server(a.id, name: "Right")
        let left = try Environment(tree, folder: "left", notifications: center, saved: [a])
        let right = try Environment(tree, folder: "right", notifications: center, saved: [b])
        let window = BrowserWindowController(location: tree.url("left"), services: left.services)
        defer { window.window?.close(); withExtendedLifetime((left, right)) {} }
        let sheet = window.serverController(editing: a)
        var delivered: RemoteServer?
        sheet.onServer = { delivered = $0 }
        let before = tree.snapshot()
        let connect = try #require(views(sheet.view, of: NSButton.self).first { $0.action == NSSelectorFromString("connect:") })
        #expect(connect.sendAction(connect.action, to: connect.target))
        let request = try #require(sheet.connecting)
        await request.value
        #expect(delivered == a)
        #expect(left.network.logins.withLock { $0.count == 1 && $0[0].0 == a && $0[0].1 == "left" })
        #expect(right.network.logins.withLock { $0.isEmpty })
        #expect(left.remote.status.connected == [a.id] && right.remote.status.connected.isEmpty)
        #expect(left.remote.servers.all == [a] && right.remote.servers.all == [b])
        await left.remote.sessions.disconnect(a.id)
        #expect(tree.snapshot() == before)
    }

    @Test func disconnectNotificationsMoveOnlyTheirOwnersPanes() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("left/keep", "right/keep"), center = NotificationCenter()
        let a = server(name: "Left"), b = server(a.id, name: "Right")
        let left = try Environment(tree, folder: "left", notifications: center, saved: [a])
        let right = try Environment(tree, folder: "right", notifications: center, saved: [b])
        let lp = try await left.services.remoteBrowsing.open(a), rp = try await right.services.remoteBrowsing.open(b)
        let lw = BrowserWindowController(location: lp, secondPane: lp, services: left.services)
        let rw = BrowserWindowController(location: rp, secondPane: rp, services: right.services)
        defer { lw.window?.close(); rw.window?.close(); withExtendedLifetime((left, right)) {} }
        let before = tree.snapshot(), otherLocations = rw.snapshot
        #expect(lw.snapshot.count == 2)
        #expect(lw.location.fileViewKey == lp.fileViewKey)
        #expect(left.remote.copies.server(containing: lw.location)?.server.id == a.id)
        let disconnect = try #require(left.remote.connections.disconnect(a))
        #expect(await disconnect.value)
        #expect(lw.waitingPanes.count == 2)
        #expect(lw.waitingPanes.allSatisfy { $0.folder.server == a.id })
        #expect(lw.location == Places.home)
        #expect(rw.snapshot == otherLocations && rw.waitingPanes.isEmpty)
        #expect(right.network.backend.isAlive)
        #expect(tree.snapshot() == before.filter { !$0.hasPrefix("left/cache/" + a.id + "/") })
        await right.remote.sessions.disconnect(b.id)
        #expect(tree.snapshot() == before.filter { !$0.hasPrefix("left/cache/" + a.id + "/") })
    }
}

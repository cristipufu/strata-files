import AppKit
import Security
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// A preview never borrows the application's preferences, clipboard, credentials, copy roots or History.
final class PreviewEnvironment {
    let preferences: Prefs
    var defaults: UserDefaults { preferences.defaults }
    let pasteboard = NSPasteboard.withUniqueName()
    let services: BrowserServices

    init(_ tree: TestTree, reader: DirectoryReader? = nil, windows: BrowserWindows = .headless,
         makeThumbnails: ((CopyProviders, ContainerStore) -> FileThumbnails)? = nil,
         providers: [any CopyProvider]? = nil,
         cloudFolders: @escaping @Sendable () async -> [CloudFolder] = { [] },
         remoteConnector: RemoteConnector = RemoteConnector { _, _ in throw RemoteError.unknownServer }) throws {
        _ = NSApplication.shared
        preferences = try Prefs.isolated()
        preferences.showIconPreviews = false
        let storage = SecureStorage.Context(directory: tree.url("environment/state"), caches: tree.url("environment/caches"), key: nil)
        let credentials = RemoteKeychain(access: KeychainAccess(
            copy: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecSuccess },
            update: { _, _ in errSecSuccess }, delete: { _ in errSecSuccess }))
        let remote = RemoteServices(preferences: preferences, credentials: credentials,
                                    copyRoot: tree.url("environment/servers"), connector: remoteConnector, notifications: NotificationCenter())
        let containers = ContainerFiles(copies: ContainerCopyStore(root: tree.url("environment/containers")))
        let copies = providers.map { CopyProviders($0, remoteCopies: remote.copies, containerCopies: containers.copies,
                                                  clipboardRoot: tree.url("environment/clipboard")) }
            ?? CopyProviders(servers: remote.files, containers: containers, clipboardRoot: tree.url("environment/clipboard"))
        let transfers = TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: .live), copies: copies)
        let containerStore = ContainerStore()
        services = BrowserServices.configured(transfers: transfers, visits: Frecency(preferences: preferences.defaults), windows: windows,
                                              remote: remote, containers: containers, containerStore: containerStore,
                                              clipboard: Clipboard(pasteboard: pasteboard, notifications: NotificationCenter()), directories: reader,
                                              thumbnails: makeThumbnails?(copies, containerStore), cloudFolders: cloudFolders)
    }

    isolated deinit {
        services.previews.close()
        pasteboard.releaseGlobally()
    }
}

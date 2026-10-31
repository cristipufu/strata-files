import AppKit
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// Browser services whose container copies live in their own temporary store, with no live engine: the Inspector
/// shows these containers' cards and files as it would a real engine's.
final class InspectorContainerEnvironment {
    let containerCopies: ContainerCopyStore
    let services: BrowserServices

    init(_ tree: TestTree, folder: String = "env", engine: ContainerEngine? = nil, containers: [ContainerInfo] = []) throws {
        let preferences = try Prefs.isolated()
        preferences.showIconPreviews = false
        let storage = SecureStorage.Context(directory: tree.url(folder + "/state"), caches: tree.url(folder + "/state/Caches"), key: nil)
        containerCopies = ContainerCopyStore(root: tree.url(folder + "/containers"))
        let containerFiles = ContainerFiles(copies: containerCopies)
        let keychain = RemoteKeychain(access: KeychainAccess(
            copy: { _ in (errSecItemNotFound, nil) },
            add: { _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        ))
        let remote = RemoteServices(preferences: preferences, credentials: keychain, copyRoot: tree.url(folder + "/servers"),
                                    notifications: NotificationCenter())
        let copies = CopyProviders(servers: remote.files, containers: containerFiles, clipboardRoot: tree.url(folder + "/clipboard"))
        services = BrowserServices.configured(
            transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: .live), copies: copies),
            visits: Frecency(preferences: preferences.defaults),
            windows: .headless,
            remote: remote,
            containers: containerFiles,
            containerStore: ContainerStore(engine: engine, containers: containers),
            clipboard: Clipboard(pasteboard: NSPasteboard.withUniqueName()),
            directories: DirectoryReader { _, _, _ in [] })
    }
}

import AppKit
import CryptoKit
import Security
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// A window's services of its own: preferences, saved state, a pasteboard, server credentials and containers that
/// refuse everything, so nothing reaches the app's or a live connection.
final class IndependentEnvironment {
    let state: TestTree
    let storage: SecureStorage.Context
    let services: BrowserServices

    init() throws {
        state = try TestTree()
        let preferences = try Prefs.isolated()
        preferences.showIconPreviews = false
        storage = SecureStorage.Context(directory: state.url("state"), caches: state.url("cache"),
                                        key: SymmetricKey(size: .bits256))
        let credentials = RemoteKeychain(access: KeychainAccess(
            copy: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecNotAvailable },
            update: { _, _ in errSecNotAvailable }, delete: { _ in errSecItemNotFound }))
        let containers = ContainerFiles(copies: ContainerCopyStore(root: state.url("containers")),
            readListing: { _, _ in throw ContainerAPIError.notFound },
            readFile: { _, _, _, _ in throw ContainerAPIError.notFound },
            readTree: { _, _, _, _ in throw ContainerAPIError.notFound })
        services = BrowserServices.isolated(preferences: preferences, storage: storage, credentials: credentials,
            connector: RemoteConnector { _, _ in throw RemoteError.unknownServer },
            clipboard: Clipboard(pasteboard: .withUniqueName(), notifications: NotificationCenter()), containers: containers)
    }

    isolated deinit {
        services.clipboard.pasteboard.releaseGlobally()
    }
}

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
    var preferences: Prefs { services.preferences }
    var defaults: UserDefaults { preferences.defaults }

    init(directories: DirectoryReader? = nil, preferences supplied: Prefs? = nil,
         mediaDetailsReader: @escaping MediaDetails.Reader = MediaDetails.read,
         placeReads: @escaping ([String]) async -> PlaceChecks.Snapshot = PlaceChecks.read,
         showSetting: @escaping @MainActor (SettingID) -> Void = { _ in }) throws {
        state = try TestTree()
        let preferences = try supplied ?? Prefs.isolated()
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
            clipboard: Clipboard(pasteboard: .withUniqueName(), notifications: NotificationCenter()), containers: containers,
            directories: directories, mediaDetailsReader: mediaDetailsReader, placeReads: placeReads, showSetting: showSetting)
    }

    isolated deinit {
        services.clipboard.pasteboard.releaseGlobally()
    }
}

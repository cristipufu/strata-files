import Foundation

/// Services shared by a window and its panes. Production windows share one set; headless windows can own independent
/// preferences, transfers and visit history without changing AppKit's responder chain or presentation controllers.
final class BrowserServices {
    static let shared = application()

    private static func application() -> BrowserServices {
        BrowserServices(transfers: .shared, visits: .shared, windows: .native, remote: .shared,
                        containers: .shared, containerStore: .shared, clipboard: .shared,
                        cloudFolders: CloudFolders.discover, tags: .shared, cloud: .shared, git: .shared, index: .shared)
    }

    /// Build an independent environment as a unit. Its queue, History, providers and preferences agree from birth;
    /// callers supply external services explicitly so a fixture never silently borrows a native connection or clipboard.
    static func isolated(preferences: Prefs, storage: SecureStorage.Context, credentials: RemoteKeychain,
                         connector: RemoteConnector, clipboard: Clipboard,
                         containers: ContainerFiles? = nil, containerStore: ContainerStore = ContainerStore(),
                         windows: BrowserWindows = .headless, directories: DirectoryReader? = nil,
                         mediaReader: @escaping MediaInfoLoader.Reader = MediaInfoLoader.read) -> BrowserServices {
        let remote = RemoteServices(preferences: preferences, credentials: credentials,
                                    copyRoot: storage.caches.appending(path: "Servers"), connector: connector)
        let containers = containers ?? ContainerFiles(copies: ContainerCopyStore(root: storage.caches.appending(path: "Containers")))
        let copies = CopyProviders(servers: remote.files, containers: containers)
        let history = OperationLog(storage: storage, copies: copies)
        let transfers = TransferQueue(preferences: preferences, history: history, copies: copies)
        return configured(transfers: transfers, visits: Frecency(preferences: preferences.defaults), windows: windows,
                          remote: remote, containers: containers, containerStore: containerStore, clipboard: clipboard,
                          directories: directories, mediaReader: mediaReader)
    }

    /// Explicit composition for custom providers and readers. The queue is the sole owner of preferences, History
    /// and copy routing; constructing a window never reconfigures an existing queue or its active jobs.
    static func configured(transfers: TransferQueue, visits: Frecency, windows: BrowserWindows,
                           remote: RemoteServices, containers: ContainerFiles, containerStore: ContainerStore,
                           clipboard: Clipboard, directories: DirectoryReader? = nil,
                           availableCapacity: @escaping @Sendable (URL) async -> Int64? = BrowserLoading.freeSpace,
                           remoteBrowsing: RemoteBrowsing? = nil,
                           mediaReader: @escaping MediaInfoLoader.Reader = MediaInfoLoader.read,
                           thumbnails: FileThumbnails? = nil, itemInfo: ItemInfoLoader? = nil,
                           cloudFolders: @escaping @Sendable () async -> [CloudFolder] = { [] },
                           openContainer: (@MainActor @Sendable (String) async throws -> URL)? = nil,
                           tags: TagStore? = nil, cloud: CloudStore? = nil, git: GitStatusStore? = nil,
                           index: FileIndex? = nil) -> BrowserServices {
        BrowserServices(transfers: transfers, visits: visits, directories: directories, windows: windows,
                        availableCapacity: availableCapacity, remote: remote, remoteBrowsing: remoteBrowsing,
                        containers: containers, containerStore: containerStore, clipboard: clipboard,
                        mediaReader: mediaReader, thumbnails: thumbnails, itemInfo: itemInfo,
                        cloudFolders: cloudFolders, openContainer: openContainer, tags: tags, cloud: cloud, git: git,
                        index: index)
    }

    let preferences: Prefs
    lazy var workspaces = Workspaces(services: self)
    lazy var connectionSettings = ServerConnectionSettings(preferences: preferences)
    lazy var savedSearches = SavedSearches(preferences: preferences)
    lazy var viewOptions = ViewOptionsWindowController(preferences: preferences)
    lazy var previews = PreviewCoordinator(preferences: preferences, directories: directories, copies: copies,
                                          thumbnails: thumbnails, clipboard: clipboard, openFile: windows.openFile,
                                          presentPanel: windows.preview)

    let transfers: TransferQueue
    let files: FileCommands
    let visits: Frecency
    let places: PlaceChecks
    let folderNames: FolderNames
    let remote: RemoteServices
    let remoteBrowsing: RemoteBrowsing
    let containers: ContainerFiles
    let containerStore: ContainerStore
    let copies: CopyProviders
    let clipboard: Clipboard
    let cloudFolders: @Sendable () async -> [CloudFolder]
    let openContainer: @MainActor @Sendable (String) async throws -> URL
    let directories: DirectoryReader
    let mediaReader: MediaInfoLoader.Reader
    let thumbnails: FileThumbnails
    let itemInfo: ItemInfoLoader
    let availableCapacity: @Sendable (URL) async -> Int64?
    let windows: BrowserWindows
    let tags: TagStore
    let cloud: CloudStore
    let git: GitStatusStore
    let index: FileIndex
    var statuses: FileStatuses { FileStatuses(tags: tags, cloud: cloud, git: git) }

    private init(transfers: TransferQueue, visits: Frecency, directories: DirectoryReader? = nil, windows: BrowserWindows,
                 availableCapacity: @escaping @Sendable (URL) async -> Int64? = BrowserLoading.freeSpace,
                 remote: RemoteServices, remoteBrowsing: RemoteBrowsing? = nil,
                 containers: ContainerFiles, containerStore: ContainerStore, clipboard: Clipboard,
                 mediaReader: @escaping MediaInfoLoader.Reader = MediaInfoLoader.read,
                 thumbnails: FileThumbnails? = nil, itemInfo: ItemInfoLoader? = nil,
                 cloudFolders: @escaping @Sendable () async -> [CloudFolder] = { [] },
                 openContainer: (@MainActor @Sendable (String) async throws -> URL)? = nil,
                 tags: TagStore? = nil, cloud: CloudStore? = nil, git: GitStatusStore? = nil, index: FileIndex? = nil) {
        self.preferences = transfers.preferences
        self.transfers = transfers
        self.files = FileCommands(transfers: transfers)
        self.visits = visits
        self.places = PlaceChecks(preferences: transfers.preferences, visits: visits, read: PlaceChecks.read)
        self.folderNames = FolderNames(read: FolderNames.read)
        self.remote = remote
        self.remoteBrowsing = remoteBrowsing ?? remote.browsing
        self.containers = containers
        self.containerStore = containerStore
        self.copies = transfers.copies
        self.clipboard = clipboard
        self.cloudFolders = cloudFolders
        self.openContainer = openContainer ?? { id in
            guard let engine = containerStore.engine, let container = containerStore.container(id: id) else { throw ContainerAPIError.notFound }
            return try await containers.open(container, on: engine)
        }
        self.directories = directories ?? DirectoryReader(copies: self.copies)
        self.mediaReader = mediaReader
        self.thumbnails = thumbnails ?? FileThumbnails(copies: self.copies, containerStore: containerStore)
        self.itemInfo = itemInfo ?? ItemInfoLoader(copies: self.copies, containerStore: containerStore, mediaReader: mediaReader)
        self.availableCapacity = availableCapacity
        self.windows = windows
        // An environment of its own reads its own: an unstarted index, and stores no other window shares.
        self.tags = tags ?? TagStore(preferences: transfers.preferences, copies: transfers.copies)
        self.cloud = cloud ?? CloudStore()
        self.git = git ?? GitStatusStore()
        self.index = index ?? FileIndex(copies: transfers.copies)
    }
}

// swift-tools-version: 6.2
import PackageDescription

// Swift 6.3's hop-to-executor optimization drops the hop back to the caller's actor at the end of some nonisolated async
// functions (with NonisolatedNonsendingByDefault they run on their caller's actor, and must return there): code on the
// main actor that awaited one then carries on off it, and crashes (Refresh in a container's folder, after
// `LazyCopies.invalidate`). The pass is off with those compilers; the hops it would save cost nothing measurable.
#if compiler(>=6.3)
let compilerWorkarounds: [SwiftSetting] = [.unsafeFlags(["-Xllvm", "-sil-disable-pass=optimize-hop-to-executor"])]
#else
let compilerWorkarounds: [SwiftSetting] = []
#endif

let strataSwiftSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
] + compilerWorkarounds

let appOnlySources = [
    "AppDelegate+Trash.swift",
    "AppDelegate.swift",
    "MainMenu.swift",
    "MainThreadWatchdog.swift",
    "NewWindowLocation.swift",
    "Prefs.swift",
    "ShortcutStore.swift",
    "StrataCommand.swift",
    "Updates.swift",
]

let themeSources = [
    "Appearance.swift",
    "ColorTheme.swift",
    "ThemeCatalog.swift",
    "HeaderMaterialTint.swift",
    "NativeHeaderFillTint.swift",
    "NavigationItemTheme.swift",
    "ThemeAccessoryView.swift",
    "ThemedFormBackground.swift",
    "ThemeSurfaces.swift",
    "ToolbarBackdropTint.swift",
    "ToolbarThemeController.swift",
]

let appModelSources = [
    "ApplicationsFolders.swift",
    "ArchiveCache.swift",
    "CloudFolders.swift",
    "CloudStatus.swift",
    "CreatedFolders.swift",
    "DSStore.swift",
    "FileEntry.swift",
    "FileOps.swift",
    "FolderCompare.swift",
    "FolderNames.swift",
    "Frecency.swift",
    "LandedFiles.swift",
    "OperationLog.swift",
    "PlaceChecks.swift",
    "Places.swift",
    "Privacy.swift",
    "SavedSearches.swift",
    "SavedNavigation.swift",
    "ServerConnectionSettings.swift",
    "TagStore.swift",
    "Trash.swift",
    "Workspace.swift",
]

let modelSources = [
    "ChosenFile.swift",
    "FileIdentity.swift",
    "FileInfoEditing.swift",
    "FileFootprint.swift",
    "FolderSizer.swift",
    "MediaInfo.swift",
    "PipeRead.swift",
    "SecureStorage.swift",
    "ServerConnection.swift",
    "ServerMountSession.swift",
]

let indexSources = [
    "DuplicateFinder.swift",
    "FSEventsStream.swift",
    "IndexPersistence.swift",
    "IndexScanner.swift",
    "IndexSearch.swift",
    "IndexStore.swift",
    "IndexWorker.swift",
    "SpotlightSearch.swift",
    "SearchTerms.swift",
]

let package = Package(
    name: "Strata",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Updates (Check for Updates…, automatic checks), pinned to a release and verified by its checksum.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CArchiveSandbox", linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("Security")]),
        .target(name: "CArchivePreview", dependencies: ["CArchiveSandbox"], linkerSettings: [.linkedLibrary("archive.2")]),
        // The archive service, an XPC service in the app sandboxed by its entitlement, and the worker it starts for each
        // read, which inherits that sandbox (scripts/archive-service.sh assembles and signs both). The service links only
        // CArchiveSandbox, never the parser.
        .executableTarget(
            name: "StrataArchiveService",
            dependencies: ["CArchiveSandbox"],
            exclude: ["Info.plist", "ArchiveService.entitlements"]
        ),
        .executableTarget(name: "StrataArchiveWorker", dependencies: ["CArchivePreview"], exclude: ["ArchiveWorker.entitlements"]),
        .target(name: "StrataArchiveClient", path: "Sources/StrataArchiveClient", swiftSettings: strataSwiftSettings),
        // Test and development builds reach the service through this host, inside an app built around it.
        .executableTarget(
            name: "StrataArchiveHarness",
            dependencies: ["StrataArchiveClient"],
            path: "Sources/StrataArchiveHarness",
            swiftSettings: strataSwiftSettings
        ),
        .target(
            name: "StrataSupport",
            path: "Sources/Strata/Support",
            swiftSettings: strataSwiftSettings
        ),
        .target(
            name: "StrataTheme",
            path: "Sources/Strata/App",
            exclude: appOnlySources,
            sources: themeSources,
            resources: [.copy("Themes")],
            swiftSettings: strataSwiftSettings
        ),
        .target(
            name: "StrataModel",
            dependencies: ["StrataSupport"],
            path: "Sources/Strata/Model",
            exclude: appModelSources,
            sources: modelSources,
            swiftSettings: strataSwiftSettings
        ),
        .target(
            name: "StrataPreviews",
            dependencies: ["StrataSupport", "StrataTheme", "StrataModel", "StrataArchiveClient"],
            path: "Sources/Strata/Previews",
            swiftSettings: strataSwiftSettings
        ),
        .target(
            name: "StrataIndex",
            dependencies: ["StrataSupport", "StrataModel"],
            path: "Sources/Strata/Index",
            exclude: ["FileIndex.swift", "FolderSearch.swift", "NaturalQuery.swift"],
            sources: indexSources,
            swiftSettings: strataSwiftSettings
        ),
        .executableTarget(
            name: "Strata",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "StrataSupport",
                "StrataTheme",
                "StrataModel",
                "StrataPreviews",
                "StrataIndex",
            ],
            path: "Sources/Strata",
            exclude: ["Support", "Previews", "App/Themes"]
                + themeSources.map { "App/\($0)" }
                + modelSources.map { "Model/\($0)" }
                + indexSources.map { "Index/\($0)" },
            swiftSettings: strataSwiftSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("NetFS"),
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "StrataCLI",
            path: "Sources/StrataCLI",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "StrataTests",
            dependencies: [
                "Strata",
                "StrataSupport",
                "StrataTheme",
                "StrataModel",
                "StrataPreviews",
                "StrataIndex",
                "StrataArchiveClient",
            ],
            path: "Tests/StrataTests",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)

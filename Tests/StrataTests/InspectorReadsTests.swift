import AppKit
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel

/// The Inspector's Compose and container cards read what they link to on this Mac away from the main thread: each
/// shows once its read arrives, a late read never shows over a newer one, and a link leads only where something is.
@MainActor struct InspectorReadsTests {
    private let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")

    private func views(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(views) }
    private func links(_ view: NSView) -> [String] { views(view).compactMap { ($0 as? LinkButton)?.title } }
    private func labels(_ view: NSView) -> [String] { views(view).compactMap { ($0 as? NSTextField)?.stringValue } }

    @Test func aComposeCardShowsOnceItsFolderIsReadAndALateReadNeverShows() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("shop/", "plain/")
        try Data("services:\n  web:\n    image: nginx\n".utf8).write(to: tree.url("shop/compose.yaml"))
        let compose = ComposeInspectorView(preferences: try Prefs.isolated(), store: ContainerStore(containers: []))
        compose.configure(tree.url("shop"))
        #expect(compose.isHidden && compose.reading != nil)
        await compose.reading?.value
        #expect(!compose.isHidden && labels(compose).contains("web"))

        // Another folder's card waits for its read; the project's is gone meanwhile, and stays gone without Compose.
        compose.configure(tree.url("plain"))
        #expect(compose.isHidden)
        await compose.reading?.value
        #expect(compose.isHidden)

        // A read replaced by a newer folder, or by no folder, never shows its project.
        compose.configure(tree.url("shop"))
        let late = try #require(compose.reading)
        compose.configure(tree.url("plain"))
        await late.value
        await compose.reading?.value
        #expect(compose.isHidden)
        compose.configure(tree.url("shop"))
        let dropped = try #require(compose.reading)
        compose.configure(nil)
        await dropped.value
        #expect(compose.isHidden && compose.reading == nil)
        #expect(tree.snapshot() == ["plain/", "shop/", "shop/compose.yaml"])
    }

    @Test func aMountLinksToThisMacOnlyOnceItsFolderIsFoundThere() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("env/", "Sources/")
        let mounts = [
            ContainerMount(kind: .bind, name: nil, source: tree.url("Sources").path, destination: "/here", isWritable: true),
            ContainerMount(kind: .bind, name: nil, source: tree.url("Gone").path, destination: "/gone", isWritable: true),
        ]
        let container = ContainerInfo(id: String(repeating: "c", count: 64), name: "web", image: "nginx", state: .running,
                                      status: "Up", created: nil, mounts: mounts, ports: [], compose: nil)
        let environment = try InspectorContainerEnvironment(tree, engine: engine, containers: [container])
        let top = try environment.containerCopies.prepare(container, on: engine)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        let view = ContainerInspectorView(preferences: environment.services.preferences,
                                          copies: environment.containerCopies, store: environment.services.containerStore)
        view.configure(url: top)
        let here = String(localized: "from \(Format.tildePath(tree.url("Sources")))", comment: "Inspector, Mounts: the Mac folder a container mounts")
        let gone = String(localized: "from \(Format.tildePath(tree.url("Gone")))", comment: "Inspector, Mounts: the Mac folder a container mounts")
        // While it's read, neither mount links anywhere.
        #expect(!view.isHidden && !links(view).contains(here) && labels(view).contains(here))
        await view.reading?.value
        #expect(links(view).contains(here) && !links(view).contains(gone) && labels(view).contains(gone))

        // Nothing selected while it's read: the read stops, and the cards stay hidden when it would have arrived.
        let again = ContainerInspectorView(preferences: environment.services.preferences,
                                           copies: environment.containerCopies, store: environment.services.containerStore)
        again.configure(url: top)
        let abandoned = try #require(again.reading)
        again.configure(url: nil)
        #expect(again.isHidden && again.reading == nil)
        await abandoned.value
        #expect(again.isHidden && again.reading == nil)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["Sources/", "env/"] + TestTree.listing(of: tree.url("env")).map { "env/" + $0 })
    }

    @Test func aStackOpensOnlyThoseOfItsFoldersStillOnThisMac() async throws {
        let tree = try TestTree("project/", "run.command", "Tool.app/Contents/")
        var opened: [[URL]] = []
        await StackProjects.open([tree.url("run.command"), tree.url("project"), tree.url("Tool.app"), tree.url("missing")]) {
            opened.append($0)
        }.value
        #expect(opened == [[tree.url("project")]])
        // None left: nothing opens (it beeps).
        await StackProjects.open([tree.url("run.command"), tree.url("missing")]) { opened.append($0) }.value
        #expect(opened.count == 1)
        #expect(tree.snapshot() == ["Tool.app/", "Tool.app/Contents/", "project/", "run.command"])
    }
}

import AppKit
import Testing
import Synchronization
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct SessionNavigationTests {
    private final class Windows {
        var opened: [BrowserWindowController] = []
        var boundary: BrowserWindows {
            BrowserWindows(controllers: { [] }, open: { [weak self] folder, second, _, services in
                guard let self else { return nil }
                let owner = BrowserWindowController(location: folder, secondPane: second, services: services)
                owner.window?.setFrameAutosaveName("")
                owner.split.splitView.autosaveName = nil
                opened.append(owner)
                return owner
            })
        }
        func close() {
            for owner in opened {
                owner.windowWillClose(Notification(name: NSWindow.willCloseNotification))
                owner.window?.contentViewController = nil
            }
            opened = []
        }
    }

    @Test func realSessionWriterReopensEachPanesHistoryAndActiveSide() async throws {
        let tree = try TestTree("left/", "left/previous/", "left/next/", "right/", "right/previous/", "right/next/")
        let state = try TestTree(), windows = Windows()
        let environment = try PreviewEnvironment(state, windows: windows.boundary)
        defer { windows.close() }
        let owner = try #require(environment.services.windows.open(tree.url("left"), tree.url("right"), nil, environment.services))
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        for (index, side) in ["left", "right"].enumerated() {
            owner.panes[index].history.back = [.recents, .folder(tree.url(side + "/previous"))]
            owner.panes[index].history.forward = [.duplicates, .folder(tree.url(side + "/next"))]
        }
        owner.window?.makeFirstResponder(owner.panes[1].browser.focusView)
        let named = Workspaces.workspace(named: "Named", of: [owner])
        #expect(named.navigation == nil && named.activePanes == nil)
        let saved = Workspaces.workspace(named: "", of: [owner], includingNavigation: true)
        let data = try #require(SessionStorage.encode([saved]))
        environment.defaults.set(data, forKey: "lastSession")
        windows.close()
        let stored = try #require(environment.defaults.data(forKey: "lastSession"))
        let read = try #require(SessionStorage.decode(stored))
        try #require(read.count == 1)
        let restored = try #require(environment.services.workspaces.openWindows(environment.services.workspaces.plan(read[0]), name: "").first)
        for pane in restored.panes { await pane.browser.directoryReads.task?.value }
        #expect(restored.pane === restored.panes[1])
        for (index, side) in ["left", "right"].enumerated() {
            let pane = restored.panes[index]
            #expect(pane.history.back.count == 2 && pane.history.forward.count == 2)
            #expect(restored.navigateHistory(.back, in: pane))
            await pane.browser.directoryReads.task?.value
            #expect(pane.location.standardizedFileURL.fileViewKey == tree.url(side + "/previous").standardizedFileURL.fileViewKey)
            #expect(restored.navigateHistory(.forward, in: pane))
            await pane.browser.directoryReads.task?.value
            #expect(pane.location.standardizedFileURL.fileViewKey == tree.url(side).standardizedFileURL.fileViewKey)
        }
        #expect(environment.defaults.data(forKey: "lastSession") == data)
        #expect(tree.snapshot() == ["left/", "left/next/", "left/previous/", "right/", "right/next/", "right/previous/"])
        withExtendedLifetime((environment, state)) {}
    }

    @Test func missingPanesKeepTheirOwnHistoryAndTabSelection() throws {
        let left = SavedNavigation(back: [SavedDestination(kind: "folder", path: "/left-before")])
        let right = SavedNavigation(back: [SavedDestination(kind: "folder", path: "/right-before")])
        let saved = Workspace(name: "", tabs: [["/gone"], ["/gone-left", "/right"]], modes: [[0], [1, 2]],
                              navigation: [[left], [left, right]], activePanes: [0, 1], selectedTab: 1)
        let plan = WorkspacePlan(saved, exists: { $0 == "/right" })
        #expect(plan.tabs.count == 1 && plan.tabs[0].count == 1)
        #expect(plan.tabs[0][0].navigation == right && plan.tabs[0][0].active)
        #expect(plan.selectedTab == 0)
        let removed = saved.removing(["/gone", "/gone-left"])
        #expect(removed.navigation == [[right]])
        #expect(removed.activePanes == [0] && removed.selectedTab == 0)
    }

    @Test func oldSessionsAndIndependentValidWindowsSurviveMalformedNeighbors() throws {
        let old = Data(#"[{"name":"Old","tabs":[["/a"]]},17,{"name":"Bad","tabs":"x"},{"name":"Good","tabs":[["/b"]],"navigation":"broken","activePanes":[]}]"#.utf8)
        let decoded = try #require(SessionStorage.decode(old))
        #expect(decoded.map(\.name) == ["Old", "Good"])
        #expect(decoded.allSatisfy { $0.navigation == nil })
        #expect(SessionStorage.decode(Data()) == nil)
        #expect(SessionStorage.decode(Data("[".utf8)) == nil)
        let boundary = Data("[]".utf8) + Data(repeating: 32, count: SessionStorage.byteLimit - 2)
        #expect(SessionStorage.decode(boundary) == [])
        #expect(SessionStorage.decode(boundary + Data([32])) == nil)
        #expect(old == Data(#"[{"name":"Old","tabs":[["/a"]]},17,{"name":"Bad","tabs":"x"},{"name":"Good","tabs":[["/b"]],"navigation":"broken","activePanes":[]}]"#.utf8))
    }



    @Test func writersBoundLongHistoriesBeforeEncodingAndPreserveRecentSteps() throws {
        let steps = (0..<(SavedNavigation.limit + 1)).map { SavedDestination(kind: "folder", path: "/step-\($0)") }
        let saved = Workspace(name: "", tabs: [["/current"]], navigation: [[SavedNavigation(back: steps)]])
        let bytes = try #require(SessionStorage.encode([saved]))
        let windows = try #require(SessionStorage.decode(bytes))
        let history = try #require(windows.first?.history(tab: 0, pane: 0))
        #expect(history.back.count == SavedNavigation.limit)
        #expect(history.back.first?.path == "/step-1" && history.back.last?.path == "/step-100")
        let long = SavedDestination(kind: "search", query: String(repeating: "\u{1}", count: 8192))
        let many = Workspace(name: "", tabs: Array(repeating: ["/current"], count: 20),
            navigation: Array(repeating: [SavedNavigation(back: Array(repeating: long, count: 100))], count: 20))
        let bounded = try #require(SessionStorage.encode(Array(repeating: many, count: 21)))
        #expect(bounded.count <= SessionStorage.byteLimit)
        let decoded = try #require(SessionStorage.decode(bounded))
        #expect(decoded.count <= 20 && decoded.reduce(0) { $0 + $1.tabs.count } <= 80)
    }

    @Test func serverHistoryUsesItsOwnersCacheAndReopeningNeverStartsALogin() async throws {
        let tree = try TestTree("local/"), state = try TestTree(), peerState = try TestTree(), windows = Windows()
        let connects = Mutex(0)
        let connector = RemoteConnector { _, _ in connects.withLock { $0 += 1 }; throw RemoteError.unknownServer }
        let environment = try PreviewEnvironment(state, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary,
                                                   remoteConnector: connector)
        let peer = try PreviewEnvironment(peerState, remoteConnector: connector)
        defer { windows.close() }
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Session", host: "session.invalid")
        try environment.services.remote.servers.save(server)
        let url = RemoteCopies.url(forRemotePath: "/srv/project", top: environment.services.remote.copies.top(of: server.id))
        let saved = try #require(SavedDestination.capture(.folder(url), services: environment.services))
        let encoded = try JSONEncoder().encode(saved)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(state.root.path))
        #expect(saved.server == server.id && saved.path == "/srv/project")
        #expect(saved.destination(services: peer.services) == nil)
        try peer.services.remote.servers.save(server)
        let peerURL = RemoteCopies.url(forRemotePath: "/srv/project", top: peer.services.remote.copies.top(of: server.id))
        #expect(saved.destination(services: peer.services) == .folder(peerURL))
        #expect(SavedDestination(kind: "folder", path: "/../escape", server: server.id).destination(services: environment.services) == nil)
        let search = SavedDestination(kind: "search", path: "/srv/project", server: server.id, query: "invoice")
        let session = Workspace(name: "", tabs: [[tree.url("local").path]], navigation: [[SavedNavigation(current: search, back: [saved])]])
        let owner = try #require(environment.services.workspaces.openWindows(environment.services.workspaces.plan(session), name: "").first)
        await owner.browser.directoryReads.task?.value
        if case .folder = owner.destination {} else { Issue.record("Restoring a remote search must wait for an explicit request") }
        #expect(owner.pane.history.back == [.folder(url)])
        #expect(connects.withLock { $0 } == 0)
        #expect(tree.snapshot() == ["local/"])
        withExtendedLifetime((environment, peer, state, peerState)) {}
    }


    @Test func emptyWindowRecordsDoNotHideAnIndependentValidNeighbor() throws {
        let empty = Array(repeating: Workspace(name: "", tabs: []), count: 20)
        let data = try JSONEncoder().encode(empty + [Workspace(name: "Good", tabs: [["/good"]])])
        #expect(SessionStorage.decode(data)?.map(\.name) == ["Good"])
        let malformed = Workspace(name: "", tabs: [["/good", "/" + String(repeating: "x", count: 4096)]],
                                  shares: ["/Volumes/Share": String(repeating: "x", count: 8193)])
        let bytes = try #require(SessionStorage.encode([malformed]))
        let restored = try #require(SessionStorage.decode(bytes)?.first)
        #expect(restored.tabs == [["/good", ""]] && restored.shares?.isEmpty == true)
    }

    @Test func transientCopiesAreNotRememberedAsLocalFolders() throws {
        let tree = try TestTree("local/"), state = try TestTree(), windows = Windows()
        let environment = try PreviewEnvironment(state, reader: DirectoryReader { _, _, _ in [] }, windows: windows.boundary)
        defer { windows.close() }
        let owner = try #require(environment.services.windows.open(tree.url("local"), nil, nil, environment.services))
        for url in [environment.services.copies.clipboardRoot.appending(path: "staged"),
                    environment.services.copies.containerCopies.root.appending(path: "container/folder"),
                    environment.services.remote.copies.root.appending(path: UUID().uuidString + "/unknown")] {
            #expect(SavedDestination.capture(.folder(url), services: environment.services) == nil)
            #expect(SavedDestination(kind: "folder", path: url.path).destination(services: environment.services) == nil)
            owner.pane.location = url
            owner.pane.destination = .folder(url)
            owner.pane.history.back = [.folder(url), .folder(tree.url("local"))]
            let saved = Workspaces.workspace(named: "", of: [owner], includingNavigation: true)
            #expect(saved.tabs == [[Places.home.path]])
            #expect(saved.history(tab: 0, pane: 0)?.current == nil)
            #expect(saved.history(tab: 0, pane: 0)?.back.count == 1)
        }
        #expect(tree.snapshot() == ["local/"])
        withExtendedLifetime((environment, state)) {}
    }

    @Test func malformedOptionalScopeFieldsNeverBroadenASearch() throws {
        let state = try TestTree(), environment = try PreviewEnvironment(state)
        for json in [#"{"kind":"search","path":17,"query":"invoice"}"#,
                     #"{"kind":"search","server":17,"query":"invoice"}"#,
                     #"{"kind":"search","path":"/tmp","server":17,"query":"invoice"}"#] {
            let place = try JSONDecoder().decode(SavedDestination.self, from: Data(json.utf8))
            #expect(place.destination(services: environment.services) == nil)
        }
        withExtendedLifetime((environment, state)) {}
    }

    @Test func historyBoundsInvalidPlacesAndScopeCannotBecomeAnUnscopedSearch() throws {
        let state = try TestTree(), environment = try PreviewEnvironment(state)
        let source = Array(repeating: SavedDestination(kind: "recents"), count: SavedNavigation.limit + 1)
        let encoded = try JSONEncoder().encode(SavedNavigation(back: source, forward: source))
        let restored = try JSONDecoder().decode(SavedNavigation.self, from: encoded)
        #expect(restored.back.count == SavedNavigation.limit && restored.forward.count == SavedNavigation.limit)
        for bad in [SavedDestination(kind: "unknown"), SavedDestination(kind: "folder", path: "relative"),
                    SavedDestination(kind: "folder", path: "/nul\0path"), SavedDestination(kind: "folder", path: "/" + String(repeating: "x", count: 4096)),
                    SavedDestination(kind: "search", path: "relative", query: "invoice"),
                    SavedDestination(kind: "search", server: UUID().uuidString, query: "invoice"),
                    SavedDestination(kind: "search", query: String(repeating: "x", count: 8193))] {
            #expect(bad.destination(services: environment.services) == nil)
        }
        #expect(SavedDestination(kind: "search", query: "invoice").destination(services: environment.services) == .search("invoice", scope: nil))
        withExtendedLifetime((environment, state)) {}
    }
}

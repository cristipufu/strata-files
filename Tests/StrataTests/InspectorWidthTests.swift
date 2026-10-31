import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// Dragging the Inspector's divider sets its width at `.dragThatCannotResizeWindow`. Nothing the Inspector shows may
/// hold it at one width: long names give way and truncate instead.
struct InspectorWidthTests {
    private let targets: [CGFloat] = [240, 900, 300, 240]

    /// The widths `view` takes when a divider asks for each of `targets` in turn.
    private func widths(of view: NSView, height: CGFloat? = nil) -> [CGFloat] {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 2_000, height: 1_200))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        let width = view.widthAnchor.constraint(equalToConstant: targets[0])
        width.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                                     view.topAnchor.constraint(equalTo: host.topAnchor), width]
                                    + (height.map { [view.heightAnchor.constraint(equalToConstant: $0)] } ?? []))
        return targets.map { target in
            width.constant = target
            host.layoutSubtreeIfNeeded()
            return view.frame.width
        }
    }

    @Test func aContainerWithLongNamesNeverHoldsTheInspectorAtOneWidth() throws {
        _ = NSApplication.shared
        let tree = try TestTree("env/", "Sources/")
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        // An anonymous volume is named by a 64-character ID, with no place to break it.
        let volume = "a87d101f9578dcdc268becc8cb1c52ba033e4d7e4b5473a4b2abd886823458cc"
        let mounts = [
            ContainerMount(kind: .volume, name: volume, source: "/var/lib/docker/volumes/\(volume)/_data",
                           destination: "/mnt/disk0", isWritable: true),
            ContainerMount(kind: .volume, name: String(volume.reversed()), source: "/var/lib/docker/volumes/x/_data",
                           destination: "/mnt/disk1", isWritable: false),
            ContainerMount(kind: .bind, name: nil, source: tree.url("Sources").path,
                           destination: "/workspace/a-long-folder-name-inside-the-container/and-another-one", isWritable: false),
            ContainerMount(kind: .bind, name: nil, source: "/Volumes/Gone/" + String(repeating: "long-folder-", count: 8),
                           destination: "/srv", isWritable: true),
        ]
        let provider = ContainerInfo(id: String(repeating: "d", count: 64), name: "culprit-yugabyte-provider",
                                     image: "yugabytedb/yugabyte:2.20.1.3-b3", state: .running, status: "Up 3 hours",
                                     created: nil, mounts: mounts, ports: [], compose: nil)
        let environment = try InspectorContainerEnvironment(tree, engine: engine, containers: [provider])
        let top = try environment.containerCopies.prepare(provider, on: engine)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)

        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in })
        _ = inspector.view
        let entry = try #require(FileEntry(url: top))
        inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        try #require(!inspector.containerView.isHidden)
        let inspectorWidths = widths(of: inspector.view, height: 1_000)
        #expect(inspectorWidths == targets, "\(inspectorWidths)")
        // At the narrowest, a volume's ID truncates and "read-only" stays whole beside it.
        func labels(_ view: NSView) -> [NSTextField] {
            view.subviews.compactMap { $0 as? NSTextField } + view.subviews.flatMap(labels)
        }
        let all = labels(inspector.view)
        let readOnly = all.filter { $0.stringValue == String(localized: "read-only", comment: "Inspector, Mounts: the container can't change it") }
        let volumeID = try #require(all.first { $0.stringValue.contains(volume) })
        #expect(readOnly.count == 2)
        for label in readOnly { #expect(label.frame.width >= label.intrinsicContentSize.width - 0.5) }
        #expect(volumeID.frame.width < volumeID.intrinsicContentSize.width)
        withExtendedLifetime(tree) {}
    }

    @Test func aComposeProjectWithLongNamesNeverHoldsTheInspectorAtOneWidth() throws {
        let tree = try TestTree("shop/")
        let service = "yugabyte-provider-" + String(repeating: "replica", count: 10)
        try Data("services:\n  \(service):\n    image: yugabytedb/yugabyte\n  web:\n    image: nginx\n".utf8)
            .write(to: tree.url("shop/compose.yaml"))
        let labels = { (service: String) in ComposeLabels(project: "shop", service: service, workingDirectory: tree.url("shop").path) }
        let container = ContainerInfo(id: String(repeating: "e", count: 64), name: "shop-\(service)-1",
                                      image: "yugabytedb/yugabyte", state: .running, status: "Up", created: nil,
                                      mounts: [], ports: [], compose: labels(service))
        let web = ContainerInfo(id: String(repeating: "f", count: 64), name: "shop-web-" + String(repeating: "replica-", count: 8) + "1",
                                image: "nginx", state: .running, status: "Up", created: nil, mounts: [], ports: [], compose: labels("web"))
        let preferences = try Prefs.isolated()
        let compose = ComposeInspectorView(preferences: preferences, store: ContainerStore(containers: [container, web]))
        compose.configure(tree.url("shop"))
        try #require(!compose.isHidden)
        let composeWidths = widths(of: compose)
        #expect(composeWidths == targets, "\(composeWidths)")
        // At the narrowest, a container's long name truncates and its service's short name stays whole.
        func views(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(views) }
        let all = views(compose)
        let webName = try #require(all.compactMap { $0 as? NSTextField }.first { $0.stringValue == "web" })
        let webLink = try #require(all.compactMap { $0 as? LinkButton }.first { $0.title == web.name })
        #expect(webName.frame.width >= webName.intrinsicContentSize.width - 0.5)
        #expect(webLink.frame.width < webLink.intrinsicContentSize.width)
        #expect(tree.snapshot() == ["shop/", "shop/compose.yaml"])
    }
}

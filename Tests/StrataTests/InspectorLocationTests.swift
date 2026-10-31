import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// The Inspector's Where row reads as one path, in order, ending in the folder's name.
struct InspectorLocationTests {
    private func shown(_ view: InspectorLocationView) -> String {
        InspectorLocationView.plain(view.pathLabel.stringValue)
    }

    @Test func whereReadsAsOnePathEndingInTheFolderName() throws {
        let tree = try TestTree("Projects/Site/index.html")
        let folder = tree.url("Projects/Site")
        let view = InspectorLocationView(folder: folder, shownAs: folder) {}
        #expect(shown(view) == Format.tildePath(tree.url("Projects")) + "/Site")
        #expect(view.toolTip == shown(view))
        // The path leading there is secondary ink; the folder's name is primary ink and comes last.
        let text = view.pathLabel.attributedStringValue
        let name = (text.string as NSString).range(of: "Site", options: .backwards)
        #expect(text.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor === InspectorColors.secondary)
        #expect(text.attribute(.foregroundColor, at: name.location, effectiveRange: nil) as? NSColor === InspectorColors.primary)
        #expect(InspectorLocationView.plain((text.string as NSString).substring(from: name.location)) == "Site")

        // The top of the disk shows its name alone, never a stray "/" with it.
        let top = URL(fileURLWithPath: "/")
        #expect(shown(InspectorLocationView(folder: top, shownAs: top) {}) == FileManager.default.displayName(atPath: "/"))

        // Server and container folders join their location the same way; a server's top keeps its address under
        // its name, because the address describes the server instead of leading to it.
        func joined(_ name: String, in location: String, leadsHere: Bool = true) -> String {
            shown(InspectorLocationView(folder: folder, shownAs: folder, name: name, location: location,
                                        locationLeadsHere: leadsHere) {})
        }
        #expect(joined("app", in: "web-1:/srv") == "web-1:/srv/app")
        #expect(joined("etc", in: "web:/") == "web:/etc")
        #expect(joined("First Cloud", in: "s3.amazonaws.com", leadsHere: false) == "First Cloud\ns3.amazonaws.com")
        #expect(tree.snapshot() == ["Projects/", "Projects/Site/", "Projects/Site/index.html"])
    }

    @Test func thePathNamesEachFolderAsItIsStoredNotByItsDisplayName() throws {
        let tree = try TestTree("Tool.app/", "a:b/", "a/b/")
        // Finder hides an app's extension and shows a stored ":" as "/": joined to a real path, either would name
        // another place ("/Applications/Xcode", or the folder b inside a).
        let app = tree.url("Tool.app"), colon = tree.url("a:b")
        try #require(FileManager.default.displayName(atPath: app.path) == "Tool")
        try #require(FileManager.default.displayName(atPath: colon.path) == "a/b")
        let appView = InspectorLocationView(folder: app, shownAs: app) {}
        #expect(shown(appView) == Format.tildePath(tree.root) + "/Tool.app")
        #expect(appView.accessibilityLabel() == String(localized: "Show “\("Tool")”", comment: "Inspector: the item’s folder, as a button that shows it"))
        #expect(shown(InspectorLocationView(folder: colon, shownAs: colon) {}) == Format.tildePath(tree.root) + "/a:b")
        #expect(tree.snapshot() == ["Tool.app/", "a/", "a/b/", "a:b/"])
    }

    @Test func rightToLeftNamesKeepThePathReadingLeftToRight() throws {
        let folder = URL(fileURLWithPath: "/")
        // A Hebrew name, a Latin name behind an invisible right-to-left mark, and an override left open in the path.
        let cases: [(name: String, location: String)] = [("מסמכים", "~"), ("\u{200F}Docs", "~"), ("Docs", "~/a\u{202E}bc")]
        for (name, location) in cases {
            let view = InspectorLocationView(folder: folder, shownAs: folder, name: name, location: location) {}
            let text = view.pathLabel.attributedStringValue
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 2_000, height: 200))
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            // Where each visible character is drawn, from the left of the line.
            func span(_ range: NSRange) -> (min: CGFloat, max: CGFloat) {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let xs = (glyphs.location..<NSMaxRange(glyphs)).filter { !layout.propertyForGlyph(at: $0).contains(.controlCharacter) }
                    .map { layout.location(forGlyphAt: $0).x }
                return (xs.min() ?? .infinity, xs.max() ?? -.infinity)
            }
            let string = text.string as NSString
            let nameRange = string.range(of: name)
            let tilde = span(string.range(of: "~"))
            let named = span(nameRange)
            let leading = span(NSRange(location: 0, length: nameRange.location))
            let codes = { (text: String) in text.unicodeScalars.map { String($0.value, radix: 16) } }
            #expect(tilde.max < named.min, "\(codes(name)) in \(codes(location)): “~” \(tilde), name \(named)")
            #expect(leading.max < named.min, "\(codes(name)) in \(codes(location)): path \(leading), name \(named)")
        }
    }

    @Test func aLongPathWrapsInFullFollowsResizingAndLinesUpWithItsTitle() throws {
        let tree = try TestTree("Clients/Northwind Traders/Quarterly Reports/2026/")
        let folder = tree.url("Clients/Northwind Traders/Quarterly Reports/2026")
        let view = InspectorLocationView(folder: folder, shownAs: folder) {}
        let title = String(localized: "Where", comment: "Inspector row: the folder the item is in")
        let rows = InspectorRows()
        rows.set([(title, view)])
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 2_000, height: 400))
        rows.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            rows.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        let label = view.pathLabel
        let line = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 12))
        let icon = try #require(view.subviews.first { $0 is NSImageView })
        let titleField = try #require(descendants(of: rows).compactMap { $0 as? NSTextField }.first { $0.stringValue == title })
        func baseline(_ field: NSView) -> CGFloat {
            let frame = field.convert(field.bounds, to: host)
            return frame.maxY - field.firstBaselineOffsetFromTop
        }

        // Wide, then the narrowest Inspector, then wide again: the same row rewraps each way and never clips.
        for (width, wraps) in [(2_000.0, false), (240.0, true), (2_000.0, false), (240.0, true)] {
            host.setFrameSize(NSSize(width: width, height: 400))
            host.layoutSubtreeIfNeeded()
            #expect((label.frame.height >= 2 * line - 1) == wraps, "width \(width)")
            let needed = try #require(label.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000))
            #expect(needed.height <= label.bounds.height + 0.5, "Every line of the path is shown at width \(width).")
            #expect(abs(icon.frame.midY - (label.frame.maxY - line / 2)) <= 0.5,
                    "The icon is centred on the path's first line at width \(width): icon \(icon.frame), path \(label.frame)")
            #expect(icon.frame.maxX <= label.frame.minX)
            #expect(abs(baseline(label) - baseline(titleField)) <= 1, "The path's first line shares the title's baseline.")
            #expect(!view.hasAmbiguousLayout && !label.hasAmbiguousLayout)
        }
        #expect(tree.snapshot() == ["Clients/", "Clients/Northwind Traders/", "Clients/Northwind Traders/Quarterly Reports/",
                                    "Clients/Northwind Traders/Quarterly Reports/2026/"])
    }

    @Test func theIconStaysOnTheFirstLineWhateverItsImageReports() throws {
        let tree = try TestTree("Projects/Site/")
        let view = InspectorLocationView(folder: tree.url("Projects/Site"), shownAs: tree.url("Projects/Site")) {}
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let icon = try #require(view.subviews.first { $0 is NSImageView } as? NSImageView)
        let placed = icon.frame
        // A folder's icon image can be another size or not loaded yet; neither moves the icon.
        for image in [NSImage(size: NSSize(width: 512, height: 512)), NSImage(size: NSSize(width: 32, height: 32)),
                      NSImage(size: .zero), nil] {
            icon.image = image
            view.needsLayout = true
            host.layoutSubtreeIfNeeded()
            #expect(icon.frame == placed, "\(String(describing: image?.size))")
        }
        #expect(tree.snapshot() == ["Projects/", "Projects/Site/"])
    }

    @Test func containerFoldersReadAsTheirPathInTheContainerThroughTheInspector() throws {
        _ = NSApplication.shared
        let tree = try TestTree("env/")
        let environment = try InspectorContainerEnvironment(tree)
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        let web = ContainerInfo(id: String(repeating: "c", count: 64), name: "web", image: "nginx", state: .running,
                                status: "Up", created: nil, mounts: [], ports: [], compose: nil)
        let top = try environment.containerCopies.prepare(web, on: engine)
        try FileManager.default.createDirectory(at: top.appending(path: "etc/nginx"), withIntermediateDirectories: true)
        try Data("events {}\n".utf8).write(to: top.appending(path: "etc/nginx/nginx.conf"))
        try Data("{}\n".utf8).write(to: top.appending(path: "config.json"))
        try #require(environment.services.copies.containerCopies.copy(containing: top.appending(path: "config.json")) != nil)

        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in })
        _ = inspector.view
        func whereRow(_ path: String) throws -> InspectorLocationView? {
            let entry = try #require(FileEntry(url: top.appending(path: path)))
            inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
            let title = String(localized: "Where", comment: "Inspector row: the folder the item is in")
            return inspector.infoRows.shown.first { $0.title == title }?.value as? InspectorLocationView
        }
        // Nested: the folder's path in the container. At the top: the container's name with its engine under it.
        let nested = try #require(try whereRow("etc/nginx/nginx.conf"))
        #expect(shown(nested) == "web:/etc/nginx")
        #expect(nested.toolTip == "web:/etc/nginx", "Hover shows the container's path, not Strata's copy of it.")
        let atTop = try #require(try whereRow("config.json"))
        #expect(shown(atTop) == "web\nDocker")
        #expect(atTop.toolTip?.contains(environment.containerCopies.root.path) == false)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}

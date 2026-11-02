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

    /// The view once it has read the folder's name and icon.
    private func read(_ view: InspectorLocationView) async -> InspectorLocationView {
        await view.reading?.value
        return view
    }

    @Test func whereReadsAsOnePathEndingInTheFolderName() async throws {
        let tree = try TestTree("Projects/Site/index.html")
        let folder = tree.url("Projects/Site")
        let view = await read(InspectorLocationView(folder: folder, shownAs: folder, looks: FinderLooks()) {})
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
        #expect(shown(await read(InspectorLocationView(folder: top, shownAs: top, looks: FinderLooks()) {})) == FileManager.default.displayName(atPath: "/"))

        // Server and container folders join their location the same way; a server's top keeps its address under
        // its name, because the address describes the server instead of leading to it.
        func joined(_ name: String, in location: String, leadsHere: Bool = true) -> String {
            shown(InspectorLocationView(folder: folder, shownAs: folder, name: name, location: location,
                                        locationLeadsHere: leadsHere, looks: FinderLooks()) {})
        }
        #expect(joined("app", in: "web-1:/srv") == "web-1:/srv/app")
        #expect(joined("etc", in: "web:/") == "web:/etc")
        #expect(joined("First Cloud", in: "s3.amazonaws.com", leadsHere: false) == "First Cloud\ns3.amazonaws.com")
        #expect(tree.snapshot() == ["Projects/", "Projects/Site/", "Projects/Site/index.html"])
    }

    @Test func thePathNamesEachFolderAsItIsStoredNotByItsDisplayName() async throws {
        let tree = try TestTree("Tool.app/", "a:b/", "a/b/")
        // Finder hides an app's extension and shows a stored ":" as "/": joined to a real path, either would name
        // another place ("/Applications/Xcode", or the folder b inside a).
        let app = tree.url("Tool.app"), colon = tree.url("a:b")
        try #require(FileManager.default.displayName(atPath: app.path) == "Tool")
        try #require(FileManager.default.displayName(atPath: colon.path) == "a/b")
        let appView = await read(InspectorLocationView(folder: app, shownAs: app, looks: FinderLooks()) {})
        #expect(shown(appView) == Format.tildePath(tree.root) + "/Tool.app")
        #expect(appView.accessibilityLabel() == String(localized: "Show “\("Tool")”", comment: "Inspector: the item’s folder, as a button that shows it"))
        #expect(shown(await read(InspectorLocationView(folder: colon, shownAs: colon, looks: FinderLooks()) {})) == Format.tildePath(tree.root) + "/a:b")
        #expect(tree.snapshot() == ["Tool.app/", "a/", "a/b/", "a:b/"])
    }

    @Test func refreshingWhereKeepsItsLoadedNameIconAndNativeRows() async throws {
        let tree = try TestTree("Tool.app/", "a:b/")
        let looks = FinderLooks()
        // Applications with no selection shows the disk root. Finder also changes app and colon names.
        for folder in [URL(fileURLWithPath: "/"), tree.url("Tool.app"), tree.url("a:b")] {
            var selected = -1
            let location = InspectorLocationView(folder: folder, shownAs: folder, looks: looks) { selected = 0 }
            let size = InspectorRows.text("Calculating…")
            let rows = InspectorRows()
            rows.set([("Size", size), ("Where", location)])
            await location.reading?.value
            try #require(location.nameText != folder.lastPathComponent)
            let text = location.pathLabel.attributedStringValue
            let accessibleName = location.accessibilityLabel()
            let icon = try #require(location.subviews.compactMap { $0 as? NSImageView }.first)
            let image = try #require(icon.image)

            for refresh in 1...3 {
                let next = InspectorLocationView(folder: folder, shownAs: folder, looks: looks) { selected = refresh }
                rows.set([("Size", InspectorRows.text("\(refresh) MB")), ("Where", next)])
                #expect(rows.shown[0].value === size)
                #expect(size.stringValue == "\(refresh) MB")
                #expect(rows.shown[1].value === location, "A refresh keeps the loaded Where row attached.")
                #expect(location.superview != nil)
                #expect(location.pathLabel.attributedStringValue.isEqual(to: text))
                #expect(location.accessibilityLabel() == accessibleName)
                #expect(icon.image === image)
                (rows.shown[1].value as? InspectorLocationView)?.action()
                #expect(selected == refresh, "The retained row uses the newest selection's action.")
                await next.reading?.value
                #expect(rows.shown[1].value === location)
            }
        }
        #expect(tree.snapshot() == ["Tool.app/", "a:b/"])
    }

    @Test func changingWhereReplacesItsFolderOrPresentation() async throws {
        let tree = try TestTree("first/", "second/")
        let looks = FinderLooks()
        let folder = tree.url("first"), other = tree.url("second")
        let rows = InspectorRows()
        let original = InspectorLocationView(folder: folder, shownAs: folder, name: "Cloud", location: "host",
                                             locationLeadsHere: false, looks: looks) {}
        let changed = [
            InspectorLocationView(folder: other, shownAs: folder, name: "Cloud", location: "host", locationLeadsHere: false, looks: looks) {},
            InspectorLocationView(folder: folder, shownAs: other, name: "Cloud", location: "host", locationLeadsHere: false, looks: looks) {},
            InspectorLocationView(folder: folder, shownAs: folder, name: "Other cloud", location: "host", locationLeadsHere: false, looks: looks) {},
            InspectorLocationView(folder: folder, shownAs: folder, name: "Cloud", location: "other host", locationLeadsHere: false, looks: looks) {},
            InspectorLocationView(folder: folder, shownAs: folder, name: "Cloud", location: "host", locationLeadsHere: true, looks: looks) {},
        ]
        for next in changed {
            rows.set([("Where", original)])
            rows.set([("Where", next)])
            #expect(rows.shown.first?.value === next)
            #expect(original.superview == nil)
            await next.reading?.value
        }
        await original.reading?.value
        #expect(tree.snapshot() == ["first/", "second/"])
    }

    @Test func inspectorRefreshesKeepWhereAndItsCurrentSelection() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("Tool.app/first/", "Tool.app/second/", "Other.app/first/")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in })
        _ = inspector.view
        var opened: (folder: URL, item: URL)?
        inspector.onShowFolder = { opened = ($0, $1) }
        let title = String(localized: "Where", comment: "Inspector row: the folder the item is in")
        func show(_ path: String, bytes: Int64? = nil) throws -> InspectorLocationView {
            let entry = try #require(FileEntry(url: tree.url(path)))
            inspector.show(entries: [entry], folder: nil,
                           folderSize: { _ in bytes.map { FolderSize(bytes: $0, files: 1) } }, canMeasure: { _ in true })
            return try #require(inspector.infoRows.shown.first { $0.title == title }?.value as? InspectorLocationView)
        }

        let original = try show("Tool.app/first")
        await original.reading?.value
        #expect(original.nameText == "Tool")
        #expect(try show("Tool.app/first", bytes: 4096) === original)
        #expect(try show("Tool.app/second", bytes: 8192) === original)
        original.action()
        #expect(opened?.folder.path == tree.url("Tool.app").path)
        #expect(opened?.item == tree.url("Tool.app/second"))

        let other = try show("Other.app/first")
        #expect(other !== original)
        other.action()
        #expect(opened?.folder.path == tree.url("Other.app").path)
        #expect(opened?.item == tree.url("Other.app/first"))
        await other.reading?.value
        #expect(tree.snapshot() == ["Other.app/", "Other.app/first/", "Tool.app/", "Tool.app/first/", "Tool.app/second/"])
    }

    @Test func arrivingImageDimensionsKeepTheWhereRowAlreadyOnScreen() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("photo.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: tree.url("photo.png"))
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in })
        _ = inspector.view
        let entry = try #require(FileEntry(url: tree.url("photo.png")))
        func show() {
            inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        }
        func whereRow() throws -> InspectorLocationView {
            try #require(inspector.infoRows.shown.compactMap { $0.value as? InspectorLocationView }.first)
        }
        show()
        let original = try whereRow()
        show()
        #expect(try whereRow() === original)
        let before = inspector.infoRows.shown.count
        await inspector.dimensionsTask?.value
        #expect(inspector.infoRows.shown.count == before + 1)
        #expect(try whereRow() === original, "Adding a metadata row keeps the visible folder's name and icon.")
        await original.reading?.value
        #expect(tree.snapshot() == ["photo.png"])
    }

    @Test func rightToLeftNamesKeepThePathReadingLeftToRight() throws {
        let folder = URL(fileURLWithPath: "/")
        // A Hebrew name, a Latin name behind an invisible right-to-left mark, and an override left open in the path.
        let cases: [(name: String, location: String)] = [("מסמכים", "~"), ("\u{200F}Docs", "~"), ("Docs", "~/a\u{202E}bc")]
        for (name, location) in cases {
            let view = InspectorLocationView(folder: folder, shownAs: folder, name: name, location: location, looks: FinderLooks()) {}
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
        let view = InspectorLocationView(folder: folder, shownAs: folder, looks: FinderLooks()) {}
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
        let view = InspectorLocationView(folder: tree.url("Projects/Site"), shownAs: tree.url("Projects/Site"), looks: FinderLooks()) {}
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

    /// The Where row's look of a folder is read once while that item is shown, and read again once another was.
    @Test func aFoldersLookIsKeptWhileShownAndReadAgainAfter() async throws {
        let tree = try TestTree("other/")
        let looks = FinderLooks(), url = tree.url("Tool.app")
        #expect(await looks.look(url).name == "Tool.app")
        // It becomes an app, which Finder names without its extension.
        try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        looks.keep(only: [url])
        #expect(await looks.look(url).name == "Tool.app")
        looks.keep(only: [tree.url("other")])
        #expect(await looks.look(url).name == "Tool")
        #expect(tree.snapshot() == ["Tool.app/", "Tool.app/Contents/", "other/"])
    }
}

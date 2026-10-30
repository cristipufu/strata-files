import Foundation
import Testing
@testable import StrataPreviews

/// OneNote sections read as [MS-ONESTORE] and [MS-ONE] specify, from files `OneNoteFixture` writes the way OneNote
/// does.
struct OneNoteReaderTests {
    private func reader(_ data: Data, in tree: TestTree, named name: String = "Notes.one",
                        limits: OneNoteSectionReader.Limits = .init()) throws -> OneNoteSectionReader {
        try data.write(to: tree.url(name))
        return try OneNoteSectionReader(try PreviewArchiveSource(tree.url(name)).open(), limits: limits)
    }

    private func failure(_ data: Data, in tree: TestTree) -> OneStoreError? {
        anyFailure(data, in: tree) as? OneStoreError
    }

    private func anyFailure(_ data: Data, in tree: TestTree) -> Error? {
        do {
            let reader = try reader(data, in: tree)
            for page in reader.pages { _ = try reader.content(of: page) }
            return nil
        } catch {
            return error
        }
    }

    /// A revision of a page space with only its title: a manifest with no content, and the metadata.
    private func revision(_ fixture: inout OneNoteFixture, titled title: String, context: OneStoreFixture.ID = .zero,
                          dependency: OneStoreFixture.ID = .zero,
                          metadata: OneStoreFixture.ID? = nil) -> OneStoreFixture.Revision {
        let manifest = fixture.take(), page = fixture.take(), metadata = metadata ?? fixture.take()
        return OneStoreFixture.Revision(id: fixture.take(), dependency: dependency, context: context, objects: [
            .init(id: page, jcid: 0x0006_000B, content: .properties([])),
            .init(id: manifest, jcid: 0x0006_0037, content: .properties([(0x1C1F, .objects([page]))])),
            .init(id: metadata, jcid: 0x0002_0030, content: .properties([(0x1CF3, OneStoreFixture.text(title))])),
        ], roots: [(1, manifest), (2, metadata)])
    }

    @Test func pagesAreListedInTheirSeriesOrderWithTheirTitlesAndLevels() throws {
        let tree = try TestTree("outside")
        var fixture = OneNoteFixture()
        let first = fixture.page("First"), sub = fixture.page("Under it", level: 2)
        let deeper = fixture.page("Deeper", level: 3)
        let next = fixture.page("Next series"), outOfRange = fixture.page("Level nine", level: 9)
        let reader = try reader(fixture.section([[first, sub, deeper], [next, outOfRange]]), in: tree)
        #expect(reader.pages.map(\.title) == ["First", "Under it", "Deeper", "Next series", "Level nine"])
        #expect(reader.pages.map(\.level) == [0, 1, 2, 0, 2])
        #expect(tree.text("outside") == "outside")
    }

    @Test func aPageShowsItsLiveRevisionTheOneLastLabeledForTheDefaultContext() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Placeholder")
        let old = revision(&fixture, titled: "Old")
        let history = revision(&fixture, titled: "A version from yesterday", context: fixture.take())
        let current = revision(&fixture, titled: "Current")
        let index = try #require(fixture.store.spaces.firstIndex { $0.id == space })
        fixture.store.spaces[index].revisions = [old, current, history]
        let data = fixture.section([[space]])
        #expect(try reader(data, in: tree).pages.map(\.title) == ["Current"])
        // A role declaration after them labels the old revision again: it's the page now.
        fixture.store.spaces[index + 1].declarations = [(old.id, 1, .zero), (current.id, 1, fixture.take())]
        #expect(try reader(fixture.store.data(), in: tree).pages.map(\.title) == ["Old"])
        // A page whose every revision has a context of its own is only history, and isn't listed.
        fixture.store.spaces[index + 1].revisions = [history]
        fixture.store.spaces[index + 1].declarations = []
        #expect(try reader(fixture.store.data(), in: tree).pages.isEmpty)
    }

    @Test func aRevisionIncludesWhatItDependsOnAndRevisesObjectsByIdentity() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Placeholder")
        let base = revision(&fixture, titled: "Before")
        let metadata = try #require(base.roots.first { $0.role == 2 }?.id)
        // The newer revision declares only a new state of the same metadata object: the manifest comes from the base.
        var delta = revision(&fixture, titled: "After", dependency: base.id, metadata: metadata)
        delta.objects = delta.objects.filter { $0.id == metadata }
        delta.roots = []
        let index = try #require(fixture.store.spaces.firstIndex { $0.id == space })
        fixture.store.spaces[index].revisions = [base, delta]
        let reader = try reader(fixture.section([[space]]), in: tree)
        #expect(reader.pages.map(\.title) == ["After"])
        #expect(try reader.content(of: try #require(reader.pages.first)) == OneNotePageContent())
    }

    @Test func pageContentKeepsItsStructureFormattingAndLinks() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Formatted") { page in
            let title = page.element([page.text("Formatted")])
            let fieldMark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
            let hiddenLink: OneNoteFixture.Properties = [(0x1E16, .bool(true)), (0x1E14, .bool(true))]
            let link = page.paragraph([(fieldMark + "HYPERLINK \"https://example.com/a\"", hiddenLink),
                                       ("Example", [(0x1E14, .bool(true))]), (" and ", []),
                                       ("bold", [(0x1C04, .bool(true))])])
            let nested = page.element([page.text("Nested")], list: "\u{1}○")
            let bullet = page.element([page.text("Bullet")], list: "\u{1}•", children: [nested])
            let numbered = page.element([page.text("Numbered")], list: "\u{3}\u{FFFD}\u{4}.")
            let cells = ["A1", "B1", "A2", "B2"].map { [page.element([page.text($0)])] }
            let table = page.element([page.table([[cells[0], cells[1]], [cells[2], cells[3]]])])
            let outline = page.outline([page.element([link]), bullet, numbered, table])
            let second = page.outline([page.element([page.text("Second")])])
            return page.manifest(title: [title], elements: [outline, second])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        let content = try reader.content(of: try #require(reader.pages.first))
        func text(_ string: String) -> [OneNoteContent] { [.text([OneNoteRun(text: string)])] }
        #expect(content.title == [OneNoteElement(content: text("Formatted"))])
        #expect(content.outlines.count == 2 && content.outlines[1] == [OneNoteElement(content: text("Second"))])
        let items = try #require(content.outlines.first)
        #expect(items.count == 4)
        #expect(items[0].content == [.text([OneNoteRun(text: "Example", link: "https://example.com/a"),
                                            OneNoteRun(text: " and "), OneNoteRun(text: "bold", bold: true)])])
        #expect(items[1] == OneNoteElement(content: text("Bullet"), list: .bullet("•"),
                                           children: [OneNoteElement(content: text("Nested"), list: .bullet("○"))]))
        #expect(items[2] == OneNoteElement(content: text("Numbered"), list: .numbered(.lowerLetter)))
        let cells = [[text("A1"), text("B1")], [text("A2"), text("B2")]]
            .map { $0.map { [OneNoteElement(content: $0)] } }
        #expect(items[3].content == [.table(cells)])
    }

    @Test func picturesAndFilesPointAtTheirBytesInsideTheSectionNeverAtFilesBesideIt() throws {
        let tree = try TestTree("secret.png")
        var fixture = OneNoteFixture()
        let picture = Array("picture bytes".utf8), attachment = Array("attachment bytes".utf8)
        let pictureGUID = "{11111111-2222-3333-4444-555555555555}", fileGUID = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}"
        let damagedGUID = "{CCCCCCCC-2222-3333-4444-555555555555}", pastGUID = "{DDDDDDDD-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(pictureGUID, picture), (fileGUID, attachment), (damagedGUID, Array("damaged".utf8)),
                                  (pastGUID, Array("past".utf8))]
        fixture.store.fileDataBlockCounts[pastGUID] = 0xFFFF_0000
        let space = fixture.page("Media") { page in
            page.manifest(title: [], elements: [
                page.image("<ifndf>\(pictureGUID)", widthInHalfInches: 4, heightInHalfInches: 2.5),
                page.outline([page.element([page.file("Report.pdf", "<ifndf>\(fileGUID)")])]),
                // A reference to a file beside the notebook, or to data the section doesn't hold, gives no bytes.
                page.image("<file>../secret.png"), page.image("<ifndf>{99999999-2222-3333-4444-555555555555}"),
                page.image("<ifndf>\(damagedGUID)"), page.image("<ifndf>\(pastGUID)"),
            ])
        }
        // The third object's stored length runs into the footer after its data: 7 bytes fill one 8-byte unit.
        var section = fixture.section([[space]])
        let header = Data(OneStoreFixture.guid("{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}"))
        let third = try #require(section.ranges(of: header).dropFirst(2).first)
        section.replaceSubrange(third.upperBound..<third.upperBound + 8, with: OneStoreFixture.ID.le(UInt64(9)))
        try section.write(to: tree.url("Media.one"))
        let source = try PreviewArchiveSource(tree.url("Media.one")), file = try source.open()
        let reader = try OneNoteSectionReader(file)
        let outlines = try reader.content(of: try #require(reader.pages.first)).outlines.map { $0.flatMap(\.content) }
        guard outlines.count == 6, case .image(let image) = outlines[0].first,
              case .file(let report) = outlines[1].first,
              case .image(let outside) = outlines[2].first, case .image(let missing) = outlines[3].first,
              case .image(let damaged) = outlines[4].first, case .image(let past) = outlines[5].first else {
            Issue.record("Unexpected content: \(outlines)")
            return
        }
        func bytes(_ data: OneNoteData?) throws -> [UInt8]? {
            guard let data else { return nil }
            try file.seek(toOffset: data.offset)
            return try file.read(upToCount: Int(data.count)).map(Array.init)
        }
        #expect(try bytes(image.data) == picture && image.size == CGSize(width: 144, height: 90))
        #expect(image.altText == "Chosen picture")
        #expect(report.name == "Report.pdf")
        #expect(try bytes(report.data) == attachment)
        #expect(outside.data == nil && missing.data == nil && damaged.data == nil && past.data == nil)
        #expect(tree.text("secret.png") == "secret.png")
    }

    @Test func nodesATransactionNeverCommittedAreIgnored() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Committed")
        // The uncommitted node names another root object space: read, it would make the file unreadable.
        fixture.store.uncommittedRootNodes = 1
        #expect(try reader(fixture.section([[space]]), in: tree).pages.map(\.title) == ["Committed"])
    }

    @Test func otherFilesVersionsAndPasswordsAreToldApart() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Page")
        let section = fixture.section([[space]])
        #expect(failure(Data(repeating: 0x41, count: 4096), in: tree) == .notOneNote)
        #expect(failure(section.prefix(1000), in: tree) == .notOneNote)
        var notebook = fixture.store
        notebook.type = "{43FF2FA1-EFD9-4C76-9EE2-10EA5722765F}"
        notebook.oldestReader = 0x1B
        #expect(failure(notebook.data(), in: tree) == .notOneNote)
        var newer = fixture.store
        newer.oldestReader = 0x2B
        #expect(failure(newer.data(), in: tree) == .unsupportedVersion)
        var otherFormat = section
        otherFormat[0x30] ^= 0xFF
        #expect(failure(otherFormat, in: tree) == .unsupportedVersion)
        var locked = fixture.store
        locked.spaces[0].revisions[0].encoding = 2
        #expect(failure(locked.data(), in: tree) == .encrypted)
        let pipe = Pipe()
        #expect(throws: OneStoreError.malformed) { try OneNoteSectionReader(pipe.fileHandleForReading) }
    }

    @Test func damagedSectionsFailWithoutCrashingAtEveryLengthAndByte() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Damaged") { page in
            page.manifest(title: [page.element([page.text("Title")])],
                          elements: [page.outline([page.element([page.text("Body")], list: "\u{1}•")])])
        }
        let section = fixture.section([[space]])
        for length in stride(from: 1024, to: section.count, by: 7) {
            #expect(failure(section.prefix(length), in: tree) != nil, "cut at \(length)")
        }
        // Every byte changed in turn, and every 16 bytes zeroed in turn, reads or fails as a OneNote file can.
        for offset in stride(from: 0, to: section.count, by: 3) {
            var damaged = section
            damaged[offset] ^= 0x5A
            let error = anyFailure(damaged, in: tree)
            #expect(error == nil || error is OneStoreError, "byte \(offset): \(String(describing: error))")
        }
        for offset in stride(from: 0, to: section.count - 16, by: 16) {
            var damaged = section
            damaged.replaceSubrange(offset..<offset + 16, with: Data(count: 16))
            let error = anyFailure(damaged, in: tree)
            #expect(error == nil || error is OneStoreError, "bytes from \(offset): \(String(describing: error))")
        }
    }

    @Test func cyclesInListsRevisionsAndPagesStop() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let looped = fixture.page("Looped") { page in
            let element = page.element([page.text("Me again")])
            let index = page.objects.indices.last!
            // The element lists itself among the items under it.
            let text = page.text("Me again")
            page.objects[index] = OneStoreFixture.Object(id: element, jcid: 0x0006_000D, content: .properties(
                [(0x1C1F, .objects([text])), (0x1C20, .objects([element]))]))
            return page.manifest(title: [], elements: [page.outline([element])])
        }
        // The item below itself is left out, as damage is; the item itself shows.
        let loopedReader = try reader(fixture.section([[looped]]), in: tree)
        let page = try #require(loopedReader.pages.first)
        let looping = try loopedReader.content(of: page).outlines
        #expect(looping == [[OneNoteElement(content: [.text([OneNoteRun(text: "Me again")])])]])
        // Two revisions depending on each other.
        var cycle = OneNoteFixture()
        let space = cycle.page("Placeholder")
        let a = cycle.take(), b = cycle.take()
        var first = revision(&cycle, titled: "A"), second = revision(&cycle, titled: "B")
        first.id = a
        first.dependency = b
        second.id = b
        second.dependency = a
        let index = try #require(cycle.store.spaces.firstIndex { $0.id == space })
        cycle.store.spaces[index].revisions = [first, second]
        #expect(try reader(cycle.section([[space]]), in: tree).pages.isEmpty)
        // A file node list whose next fragment is itself, with more committed nodes than it holds.
        var list = Data(fixture.store.data())
        let root = Int(list.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xAC, as: UInt64.self) })
        let size = Int(list.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xB4, as: UInt32.self) })
        let itself = OneStoreFixture.ID.le(UInt64(root)) + OneStoreFixture.ID.le(UInt32(size))
        list.replaceSubrange(root + size - 20..<root + size - 8, with: itself)
        let rootID = list.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: root + 8, as: UInt32.self) }
        let log = Int(list.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xA0, as: UInt64.self) })
        var entry = log
        while list.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: entry, as: UInt32.self) }) != rootID {
            entry += 8
        }
        list[entry + 4] += 1
        #expect(failure(list, in: tree) == .malformed)
    }

    @Test func countsPastTheirDataAreRefused() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Page")
        let section = fixture.section([[space]])
        func properties(_ bytes: [UInt8]) throws -> OneStoreError? {
            try (section + Data(bytes)).write(to: tree.url("Crafted.one"))
            let store = try OneStore(try PreviewArchiveSource(tree.url("Crafted.one")).open())
            let object = StoredObject(jcid: 0x0006_000E, content: .properties(
                FileChunk(offset: UInt64(section.count), count: UInt64(bytes.count)), GlobalIDTable()))
            do { _ = try store.properties(of: object); return nil } catch { return error as? OneStoreError }
        }
        let le = { (value: UInt32) in OneStoreFixture.ID.le(value) }
        let noSpaces: UInt32 = 1 << 31
        // References counted past the stream, properties counted past the set, an array past its data, a length past
        // the chunk, a property type the spec doesn't have, and property sets nested deeper than eight.
        #expect(try properties(le(0xFF_FFFF | noSpaces) + [0, 0, 0, 0]) == .malformed)
        #expect(try properties(le(noSpaces) + [0xFF, 0xFF, 1, 2, 3, 4]) == .malformed)
        #expect(try properties(le(noSpaces) + [1, 0] + le(0x10 << 26 | 1) + le(.max) + le(0x11 << 26)) == .malformed)
        #expect(try properties(le(noSpaces) + [1, 0] + le(0x7 << 26 | 1) + le(0x3FFF_FFFF)) == .malformed)
        #expect(try properties(le(noSpaces) + [1, 0] + le(0xE << 26 | 1)) == .malformed)
        #expect(try properties(le(noSpaces) + [1, 0] + le(0x8 << 26 | 1)) == .malformed)
        let nested = (0..<10).reduce([UInt8]()) { inner, _ in [1, 0] + le(0x11 << 26 | 1) + inner } + [0, 0]
        #expect(try properties(le(noSpaces) + nested) == .tooLarge)
        func nesting(_ levels: Int) -> [UInt8] {
            le(noSpaces) + (0..<levels).reduce([UInt8]()) { inner, _ in [1, 0] + le(0x11 << 26 | 1) + inner } + [0, 0]
        }
        #expect(try properties(nesting(8)) == nil && properties(nesting(9)) == .tooLarge)
        #expect(try properties(le(noSpaces) + [1, 0] + le(0x10 << 26 | 1) + le(0)) == nil)
    }
}

extension OneNoteReaderTests {
    /// What a section shows, independent of where its parts sit in the file: each page's title and level, then its
    /// items' text and the bytes of its pictures.
    private func shown(_ data: Data, in tree: TestTree) throws -> [String] {
        let reader = try reader(data, in: tree), file = try PreviewArchiveSource(tree.url("Notes.one")).open()
        var shown: [String] = []
        func describe(_ items: [OneNoteElement]) throws {
            for item in items {
                for content in item.content {
                    switch content {
                    case .text(let runs): shown.append(runs.map(\.text).joined())
                    case .image(let image):
                        try file.seek(toOffset: image.data?.offset ?? 0)
                        let bytes = try image.data.flatMap { try file.read(upToCount: Int($0.count)) } ?? Data()
                        shown.append("picture " + String(decoding: bytes, as: UTF8.self))
                    case .table, .file: shown.append("\(content)")
                    }
                }
                try describe(item.children)
            }
        }
        for page in reader.pages {
            shown.append("\(page.title) at \(page.level)")
            let content = try reader.content(of: page)
            try describe(content.title)
            try content.outlines.forEach(describe)
        }
        return shown
    }

    @Test func everyWayOfStoringReferencesListsAndDeclarationsReadsTheSame() throws {
        let tree = try TestTree()
        func section(_ configure: (inout OneStoreFixture) -> Void) throws -> [String] {
            var fixture = OneNoteFixture()
            let guid = "{11111111-2222-3333-4444-555555555555}"
            fixture.store.fileData = [(guid, Array("its bytes".utf8))]
            let first = fixture.page("First") { page in
                page.manifest(title: [page.element([page.text("Title")])],
                              elements: [page.outline([page.element([page.text("Item")], list: "\u{1}•")]),
                                         page.image("<ifndf>\(guid)")])
            }
            let second = fixture.page("Second", level: 2)
            configure(&fixture.store)
            return try shown(fixture.section([[first, second]]), in: tree)
        }
        let expected = ["First at 0", "Title", "Item", "picture its bytes", "Second at 1"]
        #expect(try section { _ in } == expected)
        for stp in 0...3 {
            for cb in 0...3 {
                #expect(try section { $0.referenceFormat = (stp, cb) } == expected, "StpFormat \(stp), CbFormat \(cb)")
            }
        }
        #expect(try section { $0.nodesPerFragment = 1 } == expected)
        #expect(try section { $0.nodesPerFragment = 2 } == expected)
        #expect(try section { $0.transactionPerList = true; $0.entriesPerLogFragment = 2 } == expected)
        for declaration: UInt16 in [0x0A5, 0x0C4, 0x0C5] {
            #expect(try section { $0.propertySetDeclaration = declaration } == expected, "\(declaration)")
        }
        #expect(try section { $0.fileDataDeclaration = 0x073 } == expected)
        #expect(try section { store in
            store.referenceFormat = (3, 3)
            store.nodesPerFragment = 2
            store.transactionPerList = true
            store.entriesPerLogFragment = 3
            store.propertySetDeclaration = 0x0C5
            store.fileDataDeclaration = 0x073
        } == expected)
    }

    @Test func aDamagedPageIsLeftOutAndTheOthersAreListed() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let first = fixture.page("First"), damaged = fixture.page("Damaged"), last = fixture.page("Last")
        let index = try #require(fixture.store.spaces.firstIndex { $0.id == damaged })
        // Its live label names a revision no manifest declares.
        fixture.store.spaces[index].declarations = [(OneStoreFixture.ID(number: 4242), 1, .zero)]
        let reader = try reader(fixture.section([[first, damaged, last]]), in: tree)
        #expect(reader.pages.map(\.title) == ["First", "Last"] && reader.damaged == 1)
        #expect(tree.snapshot() == ["Notes.one"])
    }

    @Test func aLinksAddressEndsWithItsLinkAndRunEndsCountTheTerminatingNul() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let mark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
        let hidden: OneNoteFixture.Properties = [(0x1E16, .bool(true)), (0x1E14, .bool(true))]
        let link: OneNoteFixture.Properties = [(0x1E14, .bool(true))]
        let space = fixture.page("Links") { page in
            // A link, then, after plain text, a run marked as a link alone.
            let links = page.paragraph([(mark + "HYPERLINK \"https://a.example\"", hidden), ("A", link),
                                        (" plain ", []), ("C", link)])
            // A link right after another, whose field code gives no address.
            let unaddressed = page.paragraph([(mark + "HYPERLINK \"https://a.example\"", hidden), ("A", link),
                                              (mark + "HYPERLINK \\l \"anchor\"", hidden), ("B", link)])
            // Run ends counted up to the NUL OneNote ends the text with.
            let counted = page.paragraph([("a", [(0x1C04, .bool(true))]), ("b\0", [(0x1C05, .bool(true))]),
                                          ("", [])])
            let items = [page.element([links]), page.element([unaddressed]), page.element([counted])]
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        let items = try reader.content(of: try #require(reader.pages.first)).outlines.flatMap { $0 }
        #expect(items.map(\.content) == [
            [.text([OneNoteRun(text: "A", link: "https://a.example"), OneNoteRun(text: " plain "),
                    OneNoteRun(text: "C")])],
            [.text([OneNoteRun(text: "A", link: "https://a.example"), OneNoteRun(text: "B")])],
            [.text([OneNoteRun(text: "a", bold: true), OneNoteRun(text: "b", italic: true)])],
        ])
    }

    @Test func eachLimitHoldsExactlyAtItsBoundary() throws {
        let tree = try TestTree()
        func limits(_ change: (inout OneNoteSectionReader.Limits) -> Void) -> OneNoteSectionReader.Limits {
            var limits = OneNoteSectionReader.Limits()
            change(&limits)
            return limits
        }
        func content(_ data: Data, _ limits: OneNoteSectionReader.Limits) -> OneStoreError? {
            do {
                let reader = try reader(data, in: tree, limits: limits)
                _ = try reader.content(of: try #require(reader.pages.first))
                return nil
            } catch { return error as? OneStoreError }
        }
        // A page of two items reads five objects besides them: its manifest, the page, the outline, and each item's
        // text and that text's format.
        var two = OneNoteFixture()
        let twoItems = two.page("Two") { page in
            let outline = page.outline([page.element([page.text("1")]), page.element([page.text("2")])])
            return page.manifest(title: [], elements: [outline])
        }
        let items = two.section([[twoItems]])
        #expect(content(items, limits { $0.visitsPerPage = 9 }) == nil)
        #expect(content(items, limits { $0.visitsPerPage = 8 }) == .tooLarge)
        // Each reference counts, to objects the revision doesn't have too: one item listing twenty of them besides its
        // text takes 3 + 3 + 20 visits.
        var missing = OneNoteFixture()
        let listing = missing.page("Missing") { page in
            let absent = (0..<20).map { OneStoreFixture.ID(number: 900_000 + UInt32($0)) }
            let item = page.element([page.text("1")] + absent)
            return page.manifest(title: [], elements: [page.outline([item])])
        }
        let absentObjects = missing.section([[listing]])
        #expect(content(absentObjects, limits { $0.visitsPerPage = 26 }) == nil)
        #expect(content(absentObjects, limits { $0.visitsPerPage = 25 }) == .tooLarge)
        // Items nested k deep put k + 2 objects on the path: the outline, the items and the innermost text.
        func nested(_ depth: Int) -> Data {
            var fixture = OneNoteFixture()
            let space = fixture.page("Deep") { page in
                var item = page.element([page.text("innermost")])
                for _ in 1..<depth { item = page.element([page.text("level")], children: [item]) }
                return page.manifest(title: [], elements: [page.outline([item])])
            }
            return fixture.section([[space]])
        }
        #expect(content(nested(4), limits { $0.depth = 6 }) == nil)
        #expect(content(nested(5), limits { $0.depth = 6 }) == .tooLarge)
        // A chain of revisions, each depending on the one before.
        func chain(_ length: Int) throws -> [String] {
            var fixture = OneNoteFixture()
            let space = fixture.page("Placeholder")
            var revisions: [OneStoreFixture.Revision] = []
            for index in 0..<length {
                var next = revision(&fixture, titled: "Revision \(index + 1)", dependency: revisions.last?.id ?? .zero)
                if index > 0 { next.roots = next.roots.filter { $0.role == 2 } }
                revisions.append(next)
            }
            let position = try #require(fixture.store.spaces.firstIndex { $0.id == space })
            fixture.store.spaces[position].revisions = revisions
            return try reader(fixture.section([[space]]), in: tree, limits: limits { $0.store.dependencies = 3 })
                .pages.map(\.title)
        }
        #expect(try chain(3) == ["Revision 3"])
        #expect(throws: OneStoreError.tooLarge) { try chain(4) }
        // Pages: as many as the limit, a history-only space beside them, then one more page.
        var pages = OneNoteFixture()
        let a = pages.page("A"), b = pages.page("B"), c = pages.page("C"), history = pages.page("History")
        let historyIndex = try #require(pages.store.spaces.firstIndex { $0.id == history })
        pages.store.spaces[historyIndex].revisions[0].context = pages.take()
        let twoPages = limits { $0.pages = 2 }
        let listed = try reader(pages.section([[a, b, history]]), in: tree, limits: twoPages).pages.map(\.title)
        #expect(listed == ["A", "B"])
        pages.store.spaces.removeFirst()
        #expect(throws: OneStoreError.tooLarge) { try reader(pages.section([[a, b, c]]), in: tree, limits: twoPages) }
    }

    @Test func eachListingAndEachPageReadHasTheWholeBudgetToItself() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let pages = (1...3).map { number in
            fixture.page("Page \(number)") { page in
                let items = (1...4).map { page.element([page.text("Item \($0)")]) }
                return page.manifest(title: [], elements: [page.outline(items)])
            }
        }
        let data = fixture.section([pages])
        /// Whether listing the section, then reading its first `pages` pages in turn, fits `limits`.
        func fits(_ limits: OneNoteSectionReader.Limits, pages: Int) -> Bool {
            guard let reader = try? reader(data, in: tree, limits: limits), reader.pages.count == 3 else {
                return false
            }
            return reader.pages.prefix(pages).allSatisfy { (try? reader.content(of: $0)) != nil }
        }
        func smallest(_ set: (inout OneNoteSectionReader.Limits, Int) -> Void, pages: Int) -> Int {
            var low = 1, high = 1 << 24
            while low < high {
                let middle = (low + high) / 2
                var limits = OneNoteSectionReader.Limits()
                set(&limits, middle)
                if fits(limits, pages: pages) { high = middle } else { low = middle + 1 }
            }
            return low
        }
        let budgets: [(String, (inout OneNoteSectionReader.Limits, Int) -> Void)] = [
            ("bytes", { $0.store.bytes = UInt64($1) }), ("nodes", { $0.store.nodes = $1 }),
            ("fragments", { $0.store.fragments = $1 }),
        ]
        for (name, set) in budgets {
            // Three identical pages read within the budget one of them needs: no read inherits another's spending.
            let least = smallest(set, pages: 1)
            #expect(least < 1 << 24 && smallest(set, pages: 3) == least, "\(name)")
            var limits = OneNoteSectionReader.Limits()
            set(&limits, least - 1)
            #expect(!fits(limits, pages: 1), "\(name)")
            // A listing past its budget says so, rather than leave out the pages it didn't reach.
            set(&limits, smallest(set, pages: 0) - 1)
            #expect(throws: OneStoreError.tooLarge, "\(name)") { try reader(data, in: tree, limits: limits) }
        }
    }
}

extension OneNoteReaderTests {
    @Test func aDamagedSeriesIsLeftOutAndEachPageIsListedOnce() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let a = fixture.page("A"), b = fixture.page("B"), lost = fixture.page("In the damaged series")
        let negative = fixture.page("Level below one", level: 0xFFFF_FFFF)
        // A page listed twice, and in two series, is one page; a level below 1 is no indent.
        _ = fixture.section([[a, a, b], [lost], [a, negative]])
        let objects = fixture.store.spaces[0].revisions[0].objects
        let damaged = try #require(objects.firstIndex { $0.jcid == 0x0006_0008 }.map { $0 + 1 })
        fixture.store.spaces[0].revisions[0].objects[damaged] = OneStoreFixture.Object(
            id: objects[damaged].id, jcid: 0x0006_0008, content: .raw([0xFF, 0xFF, 0xFF, 0x00, 0x01]))
        let reader = try reader(fixture.store.data(), in: tree)
        #expect(reader.pages.map(\.title) == ["A", "B", "Level below one"] && reader.pages.map(\.level) == [0, 0, 0])
    }

    @Test func runsSurviveEmptyRunsUnmatchedFormatsAndFieldNamesInAnyCase() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let mark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
        let hidden: OneNoteFixture.Properties = [(0x1E16, .bool(true)), (0x1E14, .bool(true))]
        let link: OneNoteFixture.Properties = [(0x1E14, .bool(true))]
        let space = fixture.page("Runs") { page in
            // An empty plain run between a field code and the text it links.
            let empty = page.paragraph([(mark + "HYPERLINK \"https://a.example\"", hidden), ("", []),
                                        ("Example", link)])
            let lower = page.paragraph([(mark + "hyperlink \"https://b.example\"", hidden), ("Lower", link)])
            // A link whose style gives an empty address takes its field code's.
            let emptyAddress = page.paragraph([(mark + "HYPERLINK \"https://c.example\"", hidden),
                                               ("Empty", link + [(0x1E20, OneStoreFixture.text(""))])])
            // Run ends that don't match the formats: the text shows plain, the first format hidden or not.
            let hiddenFormat = page.object(0x0012_004D, hidden), plainFormat = page.object(0x0012_004D, [])
            let ends = OneStoreFixture.ID.le(UInt32(1)) + OneStoreFixture.ID.le(UInt32(2))
            let unmatched = page.object(0x0006_000E, [(0x1C22, OneStoreFixture.text("Shown")),
                                                      (0x1E13, .objects([hiddenFormat, plainFormat])),
                                                      (0x1E12, .bytes(ends))])
            let items = [empty, lower, emptyAddress, unmatched].map { page.element([$0]) }
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        let items = try reader.content(of: try #require(reader.pages.first)).outlines.flatMap { $0 }
        #expect(items.map(\.content) == [[.text([OneNoteRun(text: "Example", link: "https://a.example")])],
                                          [.text([OneNoteRun(text: "Lower", link: "https://b.example")])],
                                          [.text([OneNoteRun(text: "Empty", link: "https://c.example")])],
                                          [.text([OneNoteRun(text: "Shown")])]])
    }

    @Test func anAttachmentsNameIsNeverAPath() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let guid = "{11111111-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(guid, Array("bytes".utf8))]
        let space = fixture.page("Files") { page in
            let climbing = page.file("../../Library/LaunchAgents/evil.plist", "<ifndf>\(guid)")
            let container = page.fileData(0x0008_0036, "<ifndf>\(guid)")
            let windows = page.object(0x0006_0035, [(0x1D9B, .objects([container])),
                                                    (0x1D9D, OneStoreFixture.text("C:\\Users\\Someone\\Report.pdf"))])
            let dots = page.file("..", "<ifndf>\(guid)")
            return page.manifest(title: [], elements: [climbing, windows, dots])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        let names = try reader.content(of: try #require(reader.pages.first)).outlines.flatMap { $0.flatMap(\.content) }
            .compactMap { content -> String? in if case .file(let file) = content { file.name } else { nil } }
        #expect(names == ["evil.plist", "Report.pdf", ""])
    }

    @Test func aPageThatRunsOutOfBudgetAtAPictureSaysSo() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let guid = "{11111111-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(guid, Array("picture".utf8))]
        // Long text makes reading the page cost more than listing it; the picture's header is its last read.
        let space = fixture.page("Picture") { page in
            let long = page.element([page.text(String(repeating: "text ", count: 400))])
            return page.manifest(title: [], elements: [page.outline([long]), page.image("<ifndf>\(guid)")])
        }
        let data = fixture.section([[space]])
        func picture(_ bytes: Int) throws -> OneNoteImage? {
            var limits = OneNoteSectionReader.Limits()
            limits.store.bytes = UInt64(bytes)
            let reader = try reader(data, in: tree, limits: limits)
            let outlines = try reader.content(of: try #require(reader.pages.first)).outlines
            guard case .image(let image)? = outlines.last?.first?.content.first else { return nil }
            return image
        }
        var low = 1, high = 1 << 20
        while low < high {
            let middle = (low + high) / 2
            if (try? picture(middle)) != nil { high = middle } else { low = middle + 1 }
        }
        #expect(try picture(low)?.data != nil)
        #expect(throws: OneStoreError.tooLarge) { try picture(low - 1) }
    }

    @Test func extendedAsciiNamesAndFieldCodesReadAsTheyShow() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let mark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
        let guid = "{11111111-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(guid, Array("bytes".utf8))]
        let space = fixture.page("Text") { page in
            // Windows-1252's curly quotes around "q", an em dash, then 0x81, which it leaves undefined.
            let ansi = page.object(0x0006_000E, [(0x3498, .bytes([0x93, 0x71, 0x94, 0x97, 0x81]))])
            // A field code in a run not marked hidden, and one in text whose runs can't be told apart.
            let shown = page.paragraph([(mark + "HYPERLINK \"https://a.example\"", [(0x1E14, .bool(true))]),
                                        ("Shown", [(0x1E14, .bool(true))]), (" hidden", [(0x1E16, .bool(true))])])
            let fallbackText = OneStoreFixture.text(mark + "HYPERLINK \"https://b\"Plain")
            let fallback = page.object(0x0006_000E, [(0x1C22, fallbackText),
                                                     (0x1E13, .objects([page.object(0x0012_004D, [])])),
                                                     (0x1E12, .bytes(OneStoreFixture.ID.le(UInt32(3))))])
            let named = page.file("evil.plist\u{0}.pdf", "<ifndf>\(guid)")
            // A field code sharing its run with the text it links, one in the middle of plain text, and one linking a
            // place in the notebook rather than an address.
            let link: OneNoteFixture.Properties = [(0x1E14, .bool(true))]
            let combined = page.paragraph([(mark + "HYPERLINK \"https://c.example\"Click here", link)])
            let middle = page.paragraph([("before" + mark + "HYPERLINK \"https://d.example\"after", [])])
            let place = page.paragraph([(mark + "HYPERLINK \\l \"Section\"", [(0x1E16, .bool(true))]), ("Go", link)])
            let reversed = page.file("invoice\u{202E}fdp.command", "<ifndf>\(guid)")
            let items = [ansi, shown, fallback, named, combined, middle, place, reversed].map { page.element([$0]) }
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        let items = try reader.content(of: try #require(reader.pages.first)).outlines.flatMap { $0 }
        func name(_ item: OneNoteElement?) -> String? {
            if case .file(let file)? = item?.content.first { file.name } else { nil }
        }
        #expect(items.count == 8)
        #expect(items.first?.content == [.text([OneNoteRun(text: "\u{201C}q\u{201D}\u{2014}\u{FFFD}")])])
        #expect(items.dropFirst().first?.content == [.text([OneNoteRun(text: "Shown", link: "https://a.example")])])
        #expect(items.dropFirst(2).first?.content == [.text([OneNoteRun(text: "Plain")])])
        #expect(name(items.dropFirst(3).first) == "evil.plist .pdf")
        let linked = [OneNoteContent.text([OneNoteRun(text: "Click here", link: "https://c.example")])]
        #expect(items.dropFirst(4).first?.content == linked)
        #expect(items.dropFirst(5).first?.content == [.text([OneNoteRun(text: "beforeafter")])])
        #expect(items.dropFirst(6).first?.content == [.text([OneNoteRun(text: "Go")])])
        #expect(name(items.dropFirst(7).first) == "invoicefdp.command")
    }

    @Test func aPictureCutFromTheFileAfterItOpenedLeavesThePageWithoutIt() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let guid = "{11111111-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(guid, Array("picture".utf8))]
        let space = fixture.page("Cut") { page in
            page.manifest(title: [], elements: [page.outline([page.element([page.text("Kept")])]),
                                                page.image("<ifndf>\(guid)")])
        }
        let data = fixture.section([[space]])
        let reader = try reader(data, in: tree)
        // Pages come before file data in the file: cutting at the picture leaves what the page itself needs.
        let header = Data(OneStoreFixture.guid("{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}"))
        let cut = try #require(data.range(of: header)).lowerBound
        let file = try FileHandle(forWritingTo: tree.url("Notes.one"))
        try file.truncate(atOffset: UInt64(cut))
        try file.close()
        let outlines = try reader.content(of: try #require(reader.pages.first)).outlines
        #expect(outlines.first?.first?.content == [.text([OneNoteRun(text: "Kept")])])
        guard case .image(let image)? = outlines.last?.first?.content.first else {
            Issue.record("No picture")
            return
        }
        #expect(image.data == nil)
    }

    @Test func theChunkLogAndArrayLimitsHoldAtTheirBoundaries() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Page") { page in
            page.manifest(title: [], elements: [page.outline([page.element([page.text("Item")])])])
        }
        let data = fixture.section([[space]])
        func reads(_ change: (inout OneNoteSectionReader.Limits) -> Void) -> OneStoreError? {
            var limits = OneNoteSectionReader.Limits()
            change(&limits)
            do {
                let reader = try reader(data, in: tree, limits: limits)
                _ = try reader.content(of: try #require(reader.pages.first))
                return nil
            } catch { return error as? OneStoreError }
        }
        let largest = UInt64(fixture.store.largestReadBlock)
        #expect(reads { $0.store.chunk = largest } == nil)
        #expect(reads { $0.store.chunk = largest - 1 } == .tooLarge)
        // The transaction log's entries count as nodes: opening the file reads nothing else that does.
        func opens(nodes: Int) -> OneStoreError? {
            var limits = OneStore.Limits()
            limits.nodes = nodes
            do { _ = try OneStore(try PreviewArchiveSource(tree.url("Notes.one")).open(), limits: limits); return nil }
            catch { return error as? OneStoreError }
        }
        let entries = fixture.store.logEntryCount
        #expect(opens(nodes: entries) == nil && opens(nodes: entries - 1) == .tooLarge)
        // A log whose next fragment is itself, with a transaction more than it holds.
        var looped = data
        let log = Int(looped.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xA0, as: UInt64.self) })
        let size = Int(looped.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0xA8, as: UInt32.self) })
        looped.replaceSubrange(log + size - 12..<log + size,
                               with: OneStoreFixture.ID.le(UInt64(log)) + OneStoreFixture.ID.le(UInt32(size)))
        looped[0x60] += 1
        #expect(failure(looped, in: tree) == .malformed)
        // An array of property sets: as many elements as the limit, then one more.
        try data.write(to: tree.url("Arrays.one"))
        func array(_ count: Int, limit: Int) throws -> OneStoreError? {
            var limits = OneStore.Limits()
            limits.arrayElements = limit
            let le = { (value: UInt32) in OneStoreFixture.ID.le(value) }
            let sets = le(1 << 31) + [1, 0] + le(0x10 << 26 | 1) + le(UInt32(count)) + le(0x11 << 26)
                + [UInt8](repeating: 0, count: 2 * count)
            try (data + Data(sets)).write(to: tree.url("Arrays.one"))
            let store = try OneStore(try PreviewArchiveSource(tree.url("Arrays.one")).open(), limits: limits)
            let object = StoredObject(jcid: 0x0006_000E, content: .properties(
                FileChunk(offset: UInt64(data.count), count: UInt64(sets.count)), GlobalIDTable()))
            do { _ = try store.properties(of: object); return nil } catch { return error as? OneStoreError }
        }
        #expect(try array(3, limit: 3) == nil && array(4, limit: 3) == .tooLarge)
    }

    @Test func fieldArgumentsSwitchesStrayMarksAndDamagedFormatsReadAsTheyShow() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let mark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
        let link: OneNoteFixture.Properties = [(0x1E14, .bool(true))]
        let guid = "{11111111-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(guid, Array("bytes".utf8))]
        let space = fixture.page("Notes\u{202E}txt\nNext") { page in
            // An address without quotes; switches after the address; a field in plain text before the text it links;
            // a mark before an ordinary word.
            let unquoted = page.paragraph([(mark + "HYPERLINK https://x.example See the \"Budget\" sheet", link)])
            let switches = page.paragraph([(mark + "HYPERLINK \"https://a.example\" \\o \"Open\"Click", link)])
            let before = page.paragraph([("see " + mark + "HYPERLINK \"https://d.example\"", []), ("here", link)])
            let stray = page.paragraph([("Total: " + mark + "Important note", [])])
            // A run whose formatting can't be read shows unformatted.
            let damaged = page.object(0x0006_000E, [(0x1C22, OneStoreFixture.text("Kept")),
                                                    (0x1E13, .objects([page.damaged(0x0012_004D)]))])
            let separated = page.file("invoice.pdf\u{2028}.command", "<ifndf>\(guid)")
            let items = [unquoted, switches, before, stray, damaged, separated].map { page.element([$0]) }
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        #expect(reader.pages.map(\.title) == ["Notestxt Next"])
        let items = try reader.content(of: try #require(reader.pages.first)).outlines.flatMap { $0 }.map(\.content)
        #expect(items.count == 6)
        #expect(items.first == [.text([OneNoteRun(text: "See the \"Budget\" sheet", link: "https://x.example")])])
        #expect(items.dropFirst().first == [.text([OneNoteRun(text: "Click", link: "https://a.example")])])
        let before = [OneNoteContent.text([OneNoteRun(text: "see "),
                                           OneNoteRun(text: "here", link: "https://d.example")])]
        #expect(items.dropFirst(2).first == before)
        #expect(items.dropFirst(3).first == [.text([OneNoteRun(text: "Total: Important note")])])
        #expect(items.dropFirst(4).first == [.text([OneNoteRun(text: "Kept")])])
        guard case .file(let file)? = items.last?.first else {
            Issue.record("No file")
            return
        }
        #expect(file.name == "invoice.pdf .command")
    }

    @Test func namesHideNoPathAndFieldsReadAcrossSpacesSharesAndPlaces() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let mark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
        let link: OneNoteFixture.Properties = [(0x1E14, .bool(true))]
        let guid = "{11111111-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(guid, Array("bytes".utf8))]
        let space = fixture.page("Fields") { page in
            // A separator a combining mark joins, and invisible fillers before an extension.
            let climbing = page.file("../../\u{0301}evil.plist", "<ifndf>\(guid)")
            let fillers = page.file("invoice.pdf\u{3164}\u{3164}.command", "<ifndf>\(guid)")
            // A place in the notebook with its text in the same run; a no-break space; a Windows share; a mark before
            // a word in capitals; a quote that never closes.
            let place = page.paragraph([(mark + "HYPERLINK \\l \"Section\" Go to notes", link)])
            let nonBreaking = page.paragraph([(mark + "HYPERLINK\u{00A0}\"https://x.example\"Click", link)])
            let share = page.paragraph([(mark + "HYPERLINK \\\\server\\share\\doc.docx Open", link)])
            let capitals = page.paragraph([("see " + mark + "NASA data", [])])
            let unclosed = page.paragraph([(mark + "HYPERLINK \"https://u.example\"   \"unclosed", link)])
            let items = [climbing, fillers, place, nonBreaking, share, capitals, unclosed].map { page.element([$0]) }
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        let items = try reader.content(of: try #require(reader.pages.first)).outlines.flatMap { $0 }.map(\.content)
        func name(_ content: [OneNoteContent]?) -> String? {
            if case .file(let file)? = content?.first { file.name } else { nil }
        }
        #expect(items.count == 7)
        #expect(name(items.first) == "\u{0301}evil.plist")
        #expect(name(items.dropFirst().first) == "invoice.pdf.command")
        #expect(items.dropFirst(2).first == [.text([OneNoteRun(text: "Go to notes")])])
        #expect(items.dropFirst(3).first == [.text([OneNoteRun(text: "Click", link: "https://x.example")])])
        #expect(items.dropFirst(4).first == [.text([OneNoteRun(text: "Open", link: "\\\\server\\share\\doc.docx")])])
        #expect(items.dropFirst(5).first == [.text([OneNoteRun(text: "see NASA data")])])
        #expect(items.dropFirst(6).first == [.text([OneNoteRun(text: "  \"unclosed", link: "https://u.example")])])
    }

    @Test func aPageWhoseManifestIsDamagedSaysSoRatherThanShowEmpty() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let space = fixture.page("Damaged") { page in page.damaged(0x0006_0037) }
        let reader = try reader(fixture.section([[space]]), in: tree)
        #expect(reader.pages.map(\.title) == ["Damaged"])
        let page = try #require(reader.pages.first)
        #expect(throws: OneStoreError.malformed) { try reader.content(of: page) }
    }

    @Test func aPageWithoutItsPageNodeSaysSoAndAFieldEndsAtTheNextMark() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let mark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
        let missing = fixture.page("Missing") { page in
            page.object(0x0006_0037, [(0x1C1F, .objects([OneStoreFixture.ID(number: 777_777)]))])
        }
        let empty = fixture.page("Empty") { page in page.object(0x0006_0037, [(0x1C1F, .objects([]))]) }
        let fields = fixture.page("Fields") { page in
            // A hyperlink with no address, its instruction ended by the next field's mark.
            let hidden: OneNoteFixture.Properties = [(0x1E16, .bool(true)), (0x1E14, .bool(true))]
            let next = page.paragraph([(mark + "HYPERLINK " + mark + "HYPERLINK \"https://b.example\"", hidden),
                                       ("B", [(0x1E14, .bool(true))])])
            return page.manifest(title: [], elements: [page.outline([page.element([next])])])
        }
        let reader = try reader(fixture.section([[missing, empty, fields]]), in: tree)
        try #require(reader.pages.count == 3)
        #expect(throws: OneStoreError.malformed) { try reader.content(of: reader.pages[0]) }
        #expect(try reader.content(of: reader.pages[1]) == OneNotePageContent())
        let items = try reader.content(of: reader.pages[2]).outlines.flatMap { $0 }.map(\.content)
        #expect(items == [[.text([OneNoteRun(text: "B", link: "https://b.example")])]])
    }

    @Test func fieldsMarksTitlesUnendedManifestsAndTheNullIdentityReadAsTheSpecSays() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        // Group tables from index 1: CompactID 0 names no object, as in real sections' rich text.
        fixture.store.firstTableIndex = 1
        let mark = String(Character(Unicode.Scalar(UInt32(0xFDDF))!))
        let hidden: OneNoteFixture.Properties = [(0x1E16, .bool(true)), (0x1E14, .bool(true))]
        let link: OneNoteFixture.Properties = [(0x1E14, .bool(true))]
        let fields = fixture.page(mark + "HYPERLINK \"https://x.example\"Report") { page in
            // A quote the next field's mark interrupts; an empty address; a space after the mark.
            let interruptedText = mark + "HYPERLINK \"a" + mark + "HYPERLINK \"https://b.example\" text"
            let interrupted = page.paragraph([(interruptedText, link)])
            let empty = page.paragraph([(mark + "HYPERLINK \"\" \\l \"Page\"", hidden), ("Go", link)])
            let spaced = page.paragraph([(mark + " HYPERLINK \"https://s.example\"", hidden), ("Spaced", link)])
            // A run whose format names no object, beside an object the file declares with that null identity.
            page.objects.append(OneStoreFixture.Object(id: .zero, jcid: 0x0012_004D,
                                                       content: .properties([(0x1C04, .bool(true))])))
            let null = page.object(0x0006_000E, [(0x1C22, OneStoreFixture.text("Plain")), (0x1E13, .objects([.zero]))])
            let items = [interrupted, empty, spaced, null].map { page.element([$0]) }
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        // A page whose first manifest has no end of its own: the next one's start can't become part of it.
        let unended = fixture.page("Placeholder")
        let index = try #require(fixture.store.spaces.firstIndex { $0.id == unended })
        var first = revision(&fixture, titled: "First")
        first.ended = false
        fixture.store.spaces[index].revisions = [first, revision(&fixture, titled: "Second")]
        let reader = try reader(fixture.section([[fields, unended]]), in: tree)
        #expect(reader.pages.map(\.title) == ["Report"])
        let page = try #require(reader.pages.first)
        let items = try reader.content(of: page).outlines.flatMap { $0 }.map(\.content)
        #expect(items == [[.text([OneNoteRun(text: "\"atext", link: "https://b.example")])],
                          [.text([OneNoteRun(text: "Go")])],
                          [.text([OneNoteRun(text: "Spaced", link: "https://s.example")])],
                          [.text([OneNoteRun(text: "Plain")])]])
    }

    @Test func referencesInsideNestedSetsAndContextsAreReadPastInOrder() throws {
        let tree = try TestTree()
        var fixture = OneNoteFixture()
        let guid = "{11111111-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(guid, Array("bytes".utf8))]
        let space = fixture.page("Streams") { page in
            let bold = page.object(0x0012_004D, [(0x1C04, .bool(true))]), other = page.object(0x0012_004D, [])
            // Before its format, the paragraph holds a nested set referencing another object and references to
            // contexts: each takes its own place in its stream, so the format still names the paragraph's own.
            let nested: OneStoreFixture.Value = .sets([[(0x3998, .objects([other]))]])
            let contexts: OneStoreFixture.Value = .contexts([OneStoreFixture.ID(number: 888_888)])
            let paragraph = page.object(0x0006_000E, [(0x3999, nested), (0x3997, contexts),
                                                      (0x1C22, OneStoreFixture.text("Bold")),
                                                      (0x1E13, .objects([bold]))])
            // A blank attachment name gives way to the file's source path.
            let container = page.fileData(0x0008_0036, "<ifndf>\(guid)")
            let source = OneStoreFixture.text("C:\\Users\\Someone\\Real.pdf")
            let blank = page.object(0x0006_0035, [(0x1D9B, .objects([container])),
                                                  (0x1D9C, OneStoreFixture.text("\u{1}")), (0x1D9D, source)])
            let items = [page.element([paragraph]), page.element([blank])]
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        let reader = try reader(fixture.section([[space]]), in: tree)
        let items = try reader.content(of: try #require(reader.pages.first)).outlines.flatMap { $0 }.map(\.content)
        #expect(items.first == [.text([OneNoteRun(text: "Bold", bold: true)])])
        guard case .file(let file)? = items.last?.first else {
            Issue.record("No file")
            return
        }
        #expect(file.name == "Real.pdf")
        // A manifest listing only null references is an empty page, not a damaged one.
        var nulls = OneNoteFixture()
        nulls.store.firstTableIndex = 1
        let empty = nulls.page("Empty") { page in page.object(0x0006_0037, [(0x1C1F, .objects([.zero]))]) }
        let emptyReader = try self.reader(nulls.section([[empty]]), in: tree, named: "Nulls.one")
        #expect(try emptyReader.content(of: try #require(emptyReader.pages.first)) == OneNotePageContent())
    }
}

import Foundation
import Testing
@testable import StrataSearch
@testable import StrataIndex

/// What the index's search language finds in a small tree: filters, scopes, exclusions, paths, case and ranking.
struct IndexQueryTests {
    /// Noon today: the tree's dates and the queries' "today" fall on one day, whenever the tests run.
    nonisolated static let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    nonisolated static let now = UInt32(noon.timeIntervalSince1970)

    nonisolated static func store() -> IndexStore {
        let store = IndexStore()
        store.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            func add(_ name: String, _ parent: Int32, dir: Bool = false, package: Bool = false, hidden: Bool = false,
                     size: Int64 = 0, age: UInt32 = 0) -> Int32 {
                let bytes = Array(name.utf8)
                let item = ScannedItem(nameOffset: 0, nameLength: bytes.count, isDirectory: dir, isPackage: package,
                                       isSymlink: false, isHidden: hidden, isMountPoint: false, size: size, mtime: now - age)
                return bytes.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: parent).lowerBound }
            }
            let docs = add("Documents", root, dir: true, age: 3_600)
            _ = add("report.pdf", docs, size: 2_000_000, age: 3_600)
            _ = add("Report Final.PDF", docs, size: 50_000, age: 10 * 86_400)
            _ = add("notes.txt", docs, size: 10, age: 40 * 86_400)
            _ = add("archive.tar.gz", docs, size: 5_000_000, age: 2 * 86_400)
            _ = add("café.txt", docs, size: 100, age: 86_400 * 3)
            _ = add(".hidden.txt", docs, hidden: true, size: 5, age: 100)
            _ = add("budget.xlsx", docs, size: 9_000, age: 200)
            let apps = add("Applications", root, dir: true, age: 90 * 86_400)
            _ = add("Safari.app", apps, dir: true, package: true, size: 9_000_000, age: 5 * 86_400)
            let src = add("src", root, dir: true, age: 7_200)
            _ = add("main.swift", src, size: 1_000, age: 60)
            let target = add("target", src, dir: true, age: 300)
            _ = add("out.o", target, size: 40_000, age: 300)
            store.aggregate()
        }
        return store
    }

    /// The names `text` finds, best first.
    private static func found(_ text: String) -> [String] {
        IndexSearch.run(IndexQuery.parse(text, now: noon), in: store(), limit: 50).hits.map { ($0.path as NSString).lastPathComponent }
    }

    @Test func wordsMatchNamesWithoutCaseOrAccentsAndTheBestFirst() {
        #expect(Self.found("report") == ["report.pdf", "Report Final.PDF"])
        #expect(Self.found("Report case:") == ["Report Final.PDF"])
        #expect(Self.found("cafe") == ["café.txt"])
    }

    @Test func extensionsAndKinds() {
        #expect(Self.found("ext:pdf") == ["report.pdf", "Report Final.PDF"])
        #expect(Set(Self.found("ext:pdf;txt")) == ["report.pdf", "Report Final.PDF", "café.txt", "notes.txt"])
        #expect(Self.found("*.tar.gz") == ["archive.tar.gz"])
        #expect(Set(Self.found("kind:folder")) == ["Documents", "Applications", "src", "target"])
        #expect(Self.found("kind:app") == ["Safari.app"])
        #expect(Self.found("kind:spreadsheet") == ["budget.xlsx"])
    }

    @Test func sizesAndDates() {
        #expect(Set(Self.found("size:>1mb")).isSuperset(of: ["report.pdf", "archive.tar.gz"]))
        #expect(!Self.found("size:>1mb").contains("notes.txt"))
        #expect(Set(Self.found("size:1kb..100kb")).isSuperset(of: ["budget.xlsx", "main.swift", "out.o", "Report Final.PDF"]))
        #expect(Self.found("modified:today").contains("main.swift") && !Self.found("modified:today").contains("notes.txt"))
    }

    @Test func scopesExclusionsAndPaths() {
        #expect(Self.found("in:Documents notes") == ["notes.txt"])
        #expect(Self.found("in:/synthetic/src main") == ["main.swift"])
        #expect(Self.found("in:target out") == ["out.o"])
        #expect(Self.found("report -final") == ["report.pdf"])
        #expect(Self.found("!final report") == ["report.pdf"])
        // Half-typed: not an exclusion yet.
        #expect(Self.found("report -") == ["report.pdf", "Report Final.PDF"])
        #expect(Self.found("Documents/report") == ["report.pdf", "Report Final.PDF"])
        #expect(Self.found("src/target/out") == ["out.o"])
        #expect(Self.found("documents/REPORT case:").isEmpty)
    }

    @Test func patternsAndHiddenItems() {
        #expect(Self.found("regex:^re.*\\.pdf$") == ["report.pdf", "Report Final.PDF"])
        #expect(Self.found("re:[").isEmpty)
        #expect(Self.found(".hidden") == [".hidden.txt"])
        #expect(Self.found("hidden").isEmpty)
    }
}

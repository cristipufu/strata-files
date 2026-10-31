import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

@MainActor
final class RenameTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "strata-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    private func make(_ names: [String]) async throws -> [PlanItem] {
        for name in names {
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
            } else {
                try Data(name.utf8).write(to: folder.appending(path: name))
            }
        }
        let urls = names.map { folder.appending(path: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }
        return await PlanItem.load(urls)
    }

    private func names(_ rules: RenameRules, _ items: [PlanItem]) throws -> [String] {
        try rules.names(for: items).get()
    }

    @Test func replacesPlainTextIgnoringCaseByDefault() async throws {
        let items = try await make(["IMG_001.jpg", "img_002.JPG", "notes.txt"])
        var rules = RenameRules()
        rules.find = "img_"
        rules.replacement = "Photo "
        #expect(try names(rules, items) == ["Photo 001.jpg", "Photo 002.JPG", "notes.txt"])
        rules.matchCase = true
        #expect(try names(rules, items) == ["IMG_001.jpg", "Photo 002.JPG", "notes.txt"])
    }

    @Test func regularExpressionsWithGroups() async throws {
        let items = try await make(["2024-05-12 trip.png", "2023-01-02 home.png"])
        var rules = RenameRules()
        rules.useRegex = true
        rules.find = #"^(\d{4})-(\d{2})-(\d{2}) (.+)$"#
        rules.replacement = "$4 $3.$2.$1"
        #expect(try names(rules, items) == ["trip 12.05.2024.png", "home 02.01.2023.png"])
        rules.find = "(unclosed"
        #expect(throws: RenameRules.Problem.self) { try rules.names(for: items).get() }
    }

    @Test func addsTextAndKeepsExtensionsUnlessAsked() async throws {
        let items = try await make(["a.txt", "Folder/"])
        var rules = RenameRules()
        rules.mode = .add
        rules.addition = " (old)"
        #expect(try names(rules, items) == ["a (old).txt", "Folder (old)"])
        rules.addAtEnd = false
        rules.addition = "x-"
        #expect(try names(rules, items) == ["x-a.txt", "x-Folder"])
        rules.mode = .replace
        rules.find = ".txt"
        rules.replacement = ".md"
        rules.includeExtension = true
        #expect(try names(rules, items) == ["a.md", "Folder"])
    }

    @Test func formatsWithNumbersFromTheStartNumber() async throws {
        let items = try await make((1...12).map { "file\($0).txt" })
        var rules = RenameRules()
        rules.mode = .format
        rules.template = "Report {n}"
        rules.startNumber = 1
        let result = try names(rules, items)
        #expect(result.first == "Report 01.txt" && result.last == "Report 12.txt")
        rules.startNumber = 100
        #expect(try names(rules, items).first == "Report 100.txt")
    }

    @Test func changesCase() async throws {
        let items = try await make(["my holiday photo.jpg"])
        var rules = RenameRules()
        rules.mode = .changeCase
        rules.transform = .spacesToDashes
        #expect(try names(rules, items) == ["my-holiday-photo.jpg"])
        rules.transform = .uppercase
        #expect(try names(rules, items) == ["MY HOLIDAY PHOTO.jpg"])
    }

    @Test func swapsAndChainsAreAllowedButClashesAreNot() async throws {
        let items = try await make(["a.txt", "b.txt", "c.txt"])
        let swap = [items[0], items[1]]
        // a ↔ b
        let plan = PlanValidator.validate([.rename(swap[0].url, to: "b.txt"), .rename(swap[1].url, to: "a.txt")],
                                          request: .init(instruction: "", items: swap, baseFolder: folder), source: .rules,
                                          interpretation: "", allowChains: true)
        #expect(plan.steps.count == 2 && plan.excluded.isEmpty)
        // a → b while b keeps its name: refused (b itself is simply unchanged).
        let clash = PlanValidator.validate([.rename(items[0].url, to: "b.txt"), .rename(items[1].url, to: "b.txt")],
                                           request: .init(instruction: "", items: Array(items[0...1]), baseFolder: folder),
                                           source: .rules, interpretation: "", allowChains: true)
        #expect(clash.steps.isEmpty && clash.excluded.count == 1)
        // a → b, b → an invalid name, c → d: b stays, so a can't take its name; c is unaffected.
        let broken = PlanValidator.validate([.rename(items[0].url, to: "b.txt"), .rename(items[1].url, to: "c/.txt"),
                                             .rename(items[2].url, to: "d.txt")],
                                            request: .init(instruction: "", items: items, baseFolder: folder), source: .rules,
                                            interpretation: "", allowChains: true)
        #expect(broken.steps.map { $0.destination?.lastPathComponent } == ["d.txt"])
    }

    @Test func swapRunsOnDiskAndUndoes() async throws {
        let items = try await make(["one.txt", "two.txt"])
        let plan = PlanValidator.validate([.rename(items[0].url, to: "two.txt"), .rename(items[1].url, to: "one.txt")],
                                          request: .init(instruction: "", items: items, baseFolder: folder), source: .rules,
                                          interpretation: "", allowChains: true)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let outcome = await PlanExecutor.apply(plan, actionName: "Rename 2 Items", undo: undo, copies: .live, history: .shared)
        undo.endUndoGrouping()
        #expect(outcome.failures.isEmpty)
        #expect(try text("one.txt") == "two.txt" && text("two.txt") == "one.txt")
        #expect(try contents() == ["one.txt", "two.txt"])
        // ⌘Z swaps them back, ⌘⇧Z again. The undo runs a task, parking one of them under a hidden name on the way:
        // wait for the swap to finish (a busy machine can take a while), never a fixed time.
        func swapped(_ one: String, _ two: String) async -> Bool {
            for _ in 0..<100 {
                if (try? text("one.txt")) == one, (try? text("two.txt")) == two, (try? contents()) == ["one.txt", "two.txt"] { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        undo.undo()
        #expect(await swapped("one.txt", "two.txt"))
        undo.redo()
        #expect(await swapped("two.txt", "one.txt"))
        #expect(try contents() == ["one.txt", "two.txt"])
    }

    @Test func itemsInsideARenamedFolderAreLeftAlone() async throws {
        let items = try await make(["1.txt", "2.txt", "Album/", "Album/0.txt"])
        var rules = RenameRules()
        rules.mode = .format
        rules.template = "{n}"
        let plan = try rules.plan(for: items, baseFolder: folder).get()
        #expect(plan.excluded.contains { $0.source?.lastPathComponent == "0.txt" && $0.problem?.contains("Album") == true })
        #expect(!plan.steps.contains { $0.source?.lastPathComponent == "0.txt" })
        let outcome = await PlanExecutor.apply(plan, actionName: "Rename", undo: nil, copies: .live, history: .shared)
        #expect(outcome.failures.isEmpty)
        let inside = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: plan.steps.first {
            $0.source?.lastPathComponent == "Album" }?.destination?.lastPathComponent ?? "Album").path)
        #expect(inside == ["0.txt"])
    }

    @Test func formatAlwaysKeepsExtensions() async throws {
        let items = try await make(["photo.jpg", "Tool.app/"])
        var rules = RenameRules()
        rules.mode = .format
        rules.template = "{name} {n}"
        rules.includeExtension = true
        #expect(try names(rules, items) == ["photo 1.jpg", "Tool 2.app"])
    }

    @Test func hugeStartNumbersAreClamped() async throws {
        let items = try await make(["a.txt", "b.txt"])
        var rules = RenameRules()
        rules.mode = .format
        rules.template = "{n}"
        rules.startNumber = Int.max
        // Padded to the widest number used ("0999999", "1000000").
        #expect(try names(rules, items).first == "0999999.txt")
        rules.startNumber = -5
        #expect(try names(rules, items).first == "0.txt")
    }

    @Test func slowRegularExpressionsGiveUp() async throws {
        let items = try await make([String(repeating: "a", count: 40) + "b.txt"])
        var rules = RenameRules()
        rules.useRegex = true
        rules.find = "(a+)+$"
        rules.replacement = "x"
        let start = Date()
        #expect(throws: RenameRules.Problem.self) { try rules.names(for: items).get() }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    /// A parked item comes back by its name, or beside it, keeping its own extension, when something has taken that
    /// (a file or a folder): never left hidden, and nothing in the way is replaced.
    @Test func aParkedItemComesBackBesideWhatTookItsName() async throws {
        for newcomerIsFolder in [false, true] {
            let tree = try TestTree("photo.jpg", "photo 2.txt")
            let original = tree.url("photo.jpg")
            let parked = FileOps.parkingName(for: original)
            try FileManager.default.moveItem(at: original, to: parked)
            #expect(try await FileOps.unpark(parked, as: original) == original)
            try FileManager.default.moveItem(at: original, to: parked)
            if newcomerIsFolder {
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            } else {
                try Data("someone else's".utf8).write(to: original)
            }
            let now = try await FileOps.unpark(parked, as: original)
            #expect(now.lastPathComponent == "photo 2.jpg", "\(newcomerIsFolder)")
            #expect(tree.snapshot() == ["photo 2.jpg", "photo 2.txt", newcomerIsFolder ? "photo.jpg/" : "photo.jpg"])
            #expect(tree.text("photo 2.jpg") == "photo.jpg")
        }
    }

    @Test func chainsMoveInOrderAndOnlyCyclesPark() {
        let url = { (name: String) in self.folder.appending(path: name) }
        let chain = FileOps.chainSteps([(url("1"), url("2")), (url("2"), url("3")), (url("3"), url("4"))])
        #expect(chain.map { $0.from.lastPathComponent } == ["3", "2", "1"])
        #expect(!chain.contains { $0.isParking })
        let swap = FileOps.chainSteps([(url("a.txt"), url("b.txt")), (url("b.txt"), url("a.txt"))])
        #expect(swap.count == 3 && swap.filter(\.isParking).count == 1)
        #expect(swap[0].to.lastPathComponent.hasPrefix(".strata-") && swap[0].to.lastPathComponent.hasSuffix("-a.txt"))
    }

    @Test func aFailedSwapPutsEverythingBack() async throws {
        _ = try await make(["a.txt", "b.txt"])
        let a = folder.appending(path: "a.txt"), b = folder.appending(path: "b.txt")
        // A locked file can't be renamed: the swap fails halfway and is undone.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: b.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: b.path) }
        let (done, error) = await FileOps.moveAll([(a, b), (b, a)])
        #expect(done.isEmpty && error != nil)
        #expect(try contents() == ["a.txt", "b.txt"])
        #expect(try text("a.txt") == "a.txt" && text("b.txt") == "b.txt")
    }
}

import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct ArchivePreviewSafetyTests {
    private func listing(_ records: [PreviewArchiveRecord], end: PreviewArchiveListing.End = .complete) throws -> ArchiveListing {
        try ArchiveLister.tree(PreviewArchiveListing(records: records, end: end), compressed: nil, named: "pack.zip")
    }

    private func file(_ path: String, size: Int64 = 1) -> PreviewArchiveRecord {
        PreviewArchiveRecord(path: path.components(separatedBy: "/"), kind: 1, size: size, modified: .distantPast, body: nil)
    }

    private func message(_ records: [PreviewArchiveRecord], end: PreviewArchiveListing.End) -> String? {
        do {
            _ = try listing(records, end: end)
            return nil
        } catch PreviewError.message(let text, _) {
            return text
        } catch {
            return "\(error)"
        }
    }

    @Test func oversizedArchiveTotalsSaturateInsteadOfCrashing() throws {
        let result = try listing([file("folder/a", size: .max), file("folder/b", size: .max)])
        #expect(result.uncompressed == .max)
        #expect(result.root.value.size == .max)
        #expect(result.root.value.children.first?.size == .max)
        #expect(result.files == 2)
    }

    @Test func implicitArchiveFoldersHaveAnAggregateBudget() throws {
        let records = (0..<1000).map { file("folder\($0)/" + String(repeating: "nested/", count: 126) + "file") }
        let result = try listing(records)
        #expect(result.files + result.folders <= 100_000)
        #expect(result.note != nil)
        #expect(result.root.value.size == Int64(result.files))
    }

    @Test func ordinaryArchiveTreesKeepTheirContentsAndSizes() throws {
        let result = try listing([file("folder/b.txt", size: 20), file("folder/a.txt", size: 10), file("top", size: 5)])
        #expect(result.note == nil)
        #expect(result.files == 3 && result.folders == 1)
        #expect(result.root.value.children.map(\.name) == ["folder", "top"])
        #expect(result.root.value.children.first?.children.map(\.name) == ["a.txt", "b.txt"])
        #expect(result.root.value.size == 35)
    }

    @Test func aListingCutShortShowsWhatItReadAndSaysWhy() throws {
        let records = [file("a"), file("b")]
        let more = try listing(records, end: .moreEntries)
        #expect(more.files == 2 && more.note == String(localized: "Showing first \(2.formatted())", comment: "Preview footer note: only the first part is shown (a count or a size)"))
        let stopped = try listing(records, end: .stopped(.limit))
        #expect(stopped.files == 2 && stopped.note == more.note)
        let unsafe = try listing(records, end: .stopped(.unsafe))
        #expect(unsafe.files == 2 && unsafe.note == PreviewArchiveError.unsafe.localizedDescription)
        // A tree cut at its node budget says so too, before the reason the listing stopped.
        let deep = (0..<1000).map { file("folder\($0)/" + String(repeating: "nested/", count: 126) + "file") }
        let cut = try listing(deep, end: .stopped(.unsafe))
        #expect(cut.note?.hasSuffix(" · " + PreviewArchiveError.unsafe.localizedDescription) == true)
        #expect(cut.note?.hasPrefix(String(localized: "Showing first \(cut.files.formatted())", comment: "Preview footer note: only the first part is shown (a count or a size)")) == true)
    }

    @Test func aListingWithNothingToShowSaysWhy() {
        #expect(message([], end: .complete) == String(localized: "This archive is empty."))
        #expect(message([], end: .moreEntries) == PreviewArchiveError.limit.localizedDescription)
        #expect(message([], end: .stopped(.limit)) == PreviewArchiveError.limit.localizedDescription)
        #expect(message([], end: .stopped(.unsafe)) == PreviewArchiveError.unsafe.localizedDescription)
        #expect(message([], end: .stopped(.encryption)) == PreviewArchiveError.encryption.localizedDescription)
        #expect(message([], end: .stopped(.password)) == ArchiveLister.passwordProtected("pack.zip"))
        #expect(message([], end: .stopped(.unreadable)) == String(localized: "This archive couldn’t be read."))
    }
}

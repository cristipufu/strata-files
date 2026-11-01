import Foundation
import Testing
import UniformTypeIdentifiers
@testable import StrataAI
@testable import StrataFiles

/// How a plan's recipe becomes operations: which items a rename names, which it skips and why, how its title reads
/// the same pattern, and which items a grouping moves.
struct PlanExpanderTests {
    private func item(_ url: URL, taken: Date? = nil, isFolder: Bool = false, type: UTType = .jpeg) -> PlanItem {
        PlanItem(url: url, name: url.lastPathComponent, isFolder: isFolder, kind: isFolder ? "Folder" : "Image",
                 contentType: isFolder ? .folder : type, size: 1, created: nil, modified: Date(timeIntervalSince1970: 1_700_000_000),
                 captureDate: taken, cameraModel: nil)
    }

    @Test func aRenameByDateSkipsAnItemWithoutThatDateHoweverThePatternSpellsIt() throws {
        let tree = try TestTree("dated.jpg", "undated.jpg")
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        let items = [item(tree.url("dated.jpg"), taken: taken), item(tree.url("undated.jpg"))]
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        for template in ["{date} {name}", "{Date} {name}", "{DATE} {name}"] {
            let recipe = PlanRecipe(action: .rename(template: template, transforms: []), dateSource: .taken)
            let output = PlanExpander.expand(recipe, items: items, baseFolder: tree.root)
            // With no date taken, it keeps its name: it isn't named after another of its dates, or today.
            #expect(output.skipped.map(\.item.name) == ["undated.jpg"], "\(template)")
            #expect(output.skipped.map(\.reason) == ["No date taken in its metadata"], "\(template)")
            let renames = output.operations.compactMap { operation -> String? in
                guard case let .rename(url, name) = operation else { return nil }
                return url.lastPathComponent + " → " + name
            }
            #expect(renames == ["dated.jpg → \(day.string(from: taken)) dated.jpg"], "\(template)")
        }
        #expect(tree.snapshot() == ["dated.jpg", "undated.jpg"])
    }

    @Test func aPlansTitleReadsItsDatesTheWayItsRenameDoes() {
        func title(_ template: String) -> String {
            PlanRecipe(action: .rename(template: template, transforms: []), dateSource: .taken).title
        }
        for template in ["{date} {name}", "{Date} {name}", "{monthname} {name}"] {
            #expect(title(template) == "Add the date taken before each name", "\(template)")
        }
        #expect(title("{Year}-{Time}") == "Rename by date and time taken")
    }

    @Test func groupingByKindOrExtensionLeavesFoldersWhereTheyAre() throws {
        let tree = try TestTree("Inner/", "report.pdf", "photo.jpg")
        let items = [item(tree.url("Inner"), isFolder: true), item(tree.url("report.pdf"), type: .pdf), item(tree.url("photo.jpg"))]
        for key in [PlanRecipe.GroupKey.kind, .extension] {
            let output = PlanExpander.expand(PlanRecipe(action: .group(by: key, inside: nil)), items: items, baseFolder: tree.root)
            let moves = output.operations.compactMap { operation -> String? in
                guard case let .move(url, folder) = operation else { return nil }
                return url.lastPathComponent + " → " + folder
            }
            #expect(moves == (key == .kind ? ["photo.jpg → Images", "report.pdf → PDFs"] : ["photo.jpg → JPG", "report.pdf → PDF"]),
                    "\(key)")
            #expect(output.unaffected == 1 && output.skipped.isEmpty, "\(key)")
        }
        #expect(tree.snapshot() == ["Inner/", "photo.jpg", "report.pdf"])
    }

    /// A kind's English title is the text its translation starts from: a folder named after a kind falls back to it.
    @Test func eachKindsEnglishTitleIsTheTextItsTitleIsTranslatedFrom() {
        for kind in SearchFilter.Kind.allCases {
            #expect(kind.title == kind.englishTitle, "\(kind)")
        }
    }
}

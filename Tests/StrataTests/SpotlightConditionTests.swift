import Testing
@testable import StrataSearch

/// What a search's `duration:` and `kind:` terms ask Spotlight for.
struct SpotlightConditionTests {
    typealias Condition = SpotlightQuery.Condition

    /// The conditions `text` makes, beside one that always needs Spotlight so a kind alone still makes a query.
    private static func conditions(_ text: String) throws -> [Condition] {
        try #require(SpotlightQuery.parse(text + " source:github")).conditions.filter { $0.attributes != ["kMDItemWhereFroms"] }
    }

    @Test(arguments: [
        ("duration:>10m", Condition.Comparison.greater, 600.0),
        ("duration:>=1h", .greaterOrEqual, 3600),
        ("length:<30s", .less, 30),
        ("duration:<=2min", .lessOrEqual, 120),
        ("duration:90", .equal, 90),
    ])
    func aDurationComparesSeconds(text: String, comparison: Condition.Comparison, seconds: Double) throws {
        let conditions = try Self.conditions(text)
        #expect(conditions.map(\.attributes) == [["kMDItemDurationSeconds"]])
        #expect(conditions.first?.test == .compare(comparison, seconds))
        #expect(conditions.first?.isKind == false)
    }

    @Test func aDurationThatIsntOneAsksNothing() throws {
        #expect(try Self.conditions("duration:soon").isEmpty)
    }

    @Test func aKindByItsEverydayNameIsAContentType() throws {
        let pdfs = try Self.conditions("kind:pdfs")
        #expect(pdfs.map(\.test) == [.anyEquals("com.adobe.pdf")] && pdfs.allSatisfy(\.isKind))
        #expect(try Self.conditions("type:Photos").map(\.test) == [.anyEquals("public.image")])
        #expect(try Self.conditions("is:doc").map(\.test) == [.anyEquals("public.content")])
    }

    @Test func aKindTheIndexKnowsNarrowsByItsOwnRule() throws {
        let folders = try Self.conditions("kind:folder")
        #expect(folders.map(\.test) == [.equals("public.folder")] && folders.map(\.label) == ["folder"])
        #expect(try Self.conditions("kind:file").map(\.test) == [.anyEquals("public.data")])
        let swift = try Self.conditions("kind:swift")
        #expect(swift.map(\.attributes) == [["kMDItemFSName"]] && swift.allSatisfy(\.isKind))
        guard case .suffixes(let suffixes) = swift.first?.test else {
            Issue.record("not by name: \(swift)")
            return
        }
        #expect(suffixes.contains("swift"))
    }
}

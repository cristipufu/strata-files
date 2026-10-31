import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

struct SearchFiltersTests {
    @Test func quotedTermsRoundTripAndOnlyChangedFiltersAreReplaced() throws {
        let text = #""Client \"A\"" !draft in:work regex:"a\\b.*" ext:pdf ext:png size:>1mb"#
        var draft = SearchFilterDraft(text)
        #expect(draft.query() == text)
        draft.size = "1mb..2mb"
        let updated = try #require(draft.query())
        #expect(updated == #""Client \"A\"" !draft in:work regex:"a\\b.*" ext:pdf ext:png size:"1mb..2mb""#)
        let query = IndexQuery.parse(updated)
        #expect(query.minSize == 1_000_000 && query.maxSize == 2_000_000)
        #expect(query.extensions == ["pdf", "png"])
        #expect(query.regex != nil && query.excludedTerms.count == 1 && query.scopeNames.count == 1)
        let phrase = SearchTerms.split(text).first?.value
        #expect(phrase == "Client \"A\"")
        #expect(IndexQuery.tokenize(SearchTerms.quote("name \\")) == ["name \\"])
        #expect(IndexQuery.tokenize(#"regex:"\d+\.txt""#) == [#"regex:\d+\.txt"#])
    }

    @Test func naturalFiltersBecomeEquivalentExplicitFiltersWhenEdited() throws {
        let text = "pdfs from last week bigger than 10mb"
        let natural = try #require(NaturalQuery.interpret(text))
        var draft = SearchFilterDraft(text)
        #expect(draft.query() == text)
        draft.size = ">20mb"
        let updated = try #require(draft.query())
        let parsed = IndexQuery.parse(updated)
        #expect(parsed.extensions == natural.query.extensions)
        #expect(parsed.modifiedAfter == natural.query.modifiedAfter && parsed.modifiedBefore == natural.query.modifiedBefore)
        #expect(parsed.minSize == 20_000_001)
        #expect(parsed.terms == natural.query.terms)
    }

    @Test func malformedAndReversedBoundsCannotBroadenAFilter() {
        for size in ["nonsense", "2mb..1mb", "1mb..nonsense", "..", "1..2..3", "NaN", "-5"] {
            var draft = SearchFilterDraft("invoice")
            draft.size = size
            #expect(draft.query() == nil)
        }
        for modified in ["nonsense", "2030-01-01..2020-01-01", "2026-01-01..bad", ".."] {
            var draft = SearchFilterDraft("invoice")
            draft.modified = modified
            #expect(draft.query() == nil)
        }
        var draft = SearchFilterDraft("invoice")
        draft.source = String(repeating: "a", count: 8193)
        #expect(draft.query() == nil)
        var unfinished = SearchFilterDraft(#""unfinished phrase"#)
        unfinished.size = ">1mb"
        #expect(unfinished.query() == nil)
    }

    @Test func sourceSearchUsesArrayMetadataAndLiteralValues() throws {
        let query = try #require(SpotlightQuery.parse("downloaded from github"))
        #expect(query.words.isEmpty)
        #expect(query.predicate.evaluate(with: ["kMDItemWhereFroms": ["https://example.com", "https://GitHub.com/owner/repo"]]))
        #expect(!query.predicate.evaluate(with: ["kMDItemWhereFroms": ["https://example.com"]]))
        #expect(!query.predicate.evaluate(with: [:]))
        let literal = #"x" OR TRUEPREDICATE OR "x"#
        let escaped = try #require(SpotlightQuery.parse("source:" + SearchTerms.quote(literal)))
        #expect(!escaped.predicate.evaluate(with: ["kMDItemWhereFroms": ["https://example.com"]]))
        #expect(escaped.predicate.evaluate(with: ["kMDItemWhereFroms": [literal]]))
        var draft = SearchFilterDraft("invoice")
        draft.source = "https://github.com"
        #expect(draft.query() != nil)
        for text in ["!draft", "regex:a.*", "case: invoice", "work/invoice", "in:work invoice"] {
            var unsupported = SearchFilterDraft(text)
            unsupported.source = "github"
            #expect(unsupported.query() == nil)
            let direct = try #require(SpotlightQuery.parse(text + " source:github"))
            #expect(direct.unsupportedSourceFilters)
            #expect(!direct.predicate.evaluate(with: ["kMDItemWhereFroms": ["github"]]))
        }
    }

    @Test func sourceCombinesWithNameKindExtensionSizeAndDate() throws {
        let query = try #require(SpotlightQuery.parse("invoice kind:pdf ext:pdf source:github size:10..20 modified:2026-01-01..2026-02-01"))
        #expect(query.words == ["invoice"])
        var metadata: [String: Any] = ["kMDItemFSName": "Invoice.pdf", "kMDItemContentTypeTree": ["public.data", "com.adobe.pdf"],
            "kMDItemWhereFroms": ["https://github.com"], "kMDItemFSSize": 10,
            "kMDItemFSContentChangeDate": ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")!]
        #expect(query.predicate.evaluate(with: metadata))
        for size in [9, 21] { metadata["kMDItemFSSize"] = size; #expect(!query.predicate.evaluate(with: metadata)) }
        metadata["kMDItemFSSize"] = 20
        metadata["kMDItemFSName"] = "unrelated.pdf"
        #expect(!query.predicate.evaluate(with: metadata))
        metadata["kMDItemFSName"] = "Invoice.pdf"
        metadata["kMDItemFSContentChangeDate"] = ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z")!
        #expect(!query.predicate.evaluate(with: metadata))
        #expect(SpotlightQuery.parse("size:>1mb modified:today") == nil)
        let artist = try #require(SpotlightQuery.parse("artist:Miles size:>1mb"))
        #expect(artist.conditions.contains { $0.test == .anyEquals("public.audio") })
        let code = try #require(SpotlightQuery.parse("source:github kind:code"))
        #expect(code.predicate.evaluate(with: ["kMDItemWhereFroms": ["github"], "kMDItemFSName": "main.swift"]))
        #expect(!code.predicate.evaluate(with: ["kMDItemWhereFroms": ["github"], "kMDItemFSName": "photo.png"]))
    }

    @Test func filtersApplyThroughNativeControlsToTheOriginalSearchOnly() async throws {
        let tree = try TestTree("left/", "left/Invoice.pdf", "right/"), state = try TestTree()
        let environment = try PreviewEnvironment(state)
        let owner = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
        owner.window?.setFrameAutosaveName(""); owner.split.splitView.autosaveName = nil
        defer { owner.windowWillClose(Notification(name: NSWindow.willCloseNotification)); owner.window?.contentViewController = nil }
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let pane = owner.pane
        pane.destination = .search("invoice", scope: tree.url("left"))
        let controller = SearchFiltersController(query: "invoice", context: SearchFilterContext(owner))
        controller.loadViewIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(controller.view)
        let combos = controls.compactMap { $0 as? NSComboBox }
        let size = try #require(combos.first { $0.accessibilityLabel() == String(localized: "Size") })
        size.stringValue = ">1mb"
        let apply = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Apply") })
        #expect(apply.sendAction(apply.action, to: apply.target))
        #expect(pane.destination == .search(#"invoice size:">1mb""#, scope: tree.url("left")))
        let context = SearchFilterContext(owner)
        let saved = pane.destination
        pane.destination = .folder(tree.url("left")); pane.destination = saved
        #expect(!context.apply("kind:pdf"))
        let switched = SearchFilterContext(owner)
        owner.window?.makeFirstResponder(owner.panes[1].browser.focusView)
        #expect(!switched.apply("kind:pdf"))
        owner.window?.makeFirstResponder(pane.browser.focusView)
        let closed = SearchFilterContext(owner)
        owner.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!closed.apply("kind:pdf"))
        #expect(tree.snapshot() == ["left/", "left/Invoice.pdf", "right/"])
        withExtendedLifetime((environment, state)) {}
    }
}

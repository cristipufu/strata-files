import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel
@testable import StrataPreviews

@MainActor struct InspectorPreviewLifecycleTests {
    @Test func hiddenInspectorsCancelRetainedPreviewsAndLateResultsNeverApply() async throws {
        let tree = try TestTree("table.csv")
        let environment = try IndependentEnvironment()
        let (held, release) = AsyncStream<Void>.makeStream()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let operation = Task { for await _ in held {} }
        defer { release.finish() }
        let rich = PreviewView(frame: .zero)
        var applied = false
        rich.load({ signal.yield(()); await operation.value; return "late" }, apply: { _ in applied = true })
        var scheduled: [DispatchWorkItem] = []
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { scheduled.append($0) },
            makePreview: { _, _ in rich })
        inspector.loadViewIfNeeded()
        let entry = try #require(FileEntry(url: tree.url("table.csv")))
        inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        try #require(scheduled.last).perform()
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let pending = try #require(rich.loadingTask)
        #expect(inspector.richPreview === rich)
        inspector.stopPreviewing()
        #expect(pending.isCancelled && rich.loadingTask == nil && inspector.richPreview == nil)
        release.finish()
        await pending.value
        #expect(!applied)
        #expect(tree.snapshot() == ["table.csv"])
        withExtendedLifetime(environment) {}
    }

    @Test func oldWorkAndFallbacksCannotReplaceANewPreviewOfTheSameFile() throws {
        let tree = try TestTree("table.csv")
        let environment = try IndependentEnvironment()
        var scheduled: [DispatchWorkItem] = [], fallbacks: [() -> Void] = []
        var views: [PreviewView] = []
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { scheduled.append($0) },
            makePreview: { _, fallback in
                let view = PreviewView(frame: .zero)
                views.append(view); fallbacks.append(fallback)
                return view
            })
        inspector.loadViewIfNeeded()
        let entry = try #require(FileEntry(url: tree.url("table.csv")))
        func show() { inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false }) }
        show()
        let oldWork = try #require(scheduled.last)
        inspector.stopPreviewing()
        show()
        oldWork.perform()
        #expect(views.isEmpty)
        try #require(scheduled.last).perform()
        let oldFallback = try #require(fallbacks.first)
        inspector.stopPreviewing()
        show()
        try #require(scheduled.last).perform()
        let current = try #require(views.last)
        oldFallback()
        #expect(inspector.richPreview === current && views.count == 2)
        inspector.stopPreviewing()
        #expect(tree.snapshot() == ["table.csv"])
        withExtendedLifetime(environment) {}
    }

    @Test func aFactoryThatClosesItsOwnerCannotInstallTheViewItReturns() throws {
        let tree = try TestTree("table.csv")
        let environment = try IndependentEnvironment()
        weak var owner: InspectorViewController?
        var scheduled: DispatchWorkItem?
        let candidate = PreviewView(frame: .zero)
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { scheduled = $0 },
            makePreview: { _, _ in owner?.stopPreviewing(); return candidate })
        owner = inspector
        inspector.loadViewIfNeeded()
        let entry = try #require(FileEntry(url: tree.url("table.csv")))
        inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        try #require(scheduled).perform()
        #expect(inspector.richPreview == nil && candidate.superview == nil)
        #expect(tree.snapshot() == ["table.csv"])
        withExtendedLifetime(environment) {}
    }
}

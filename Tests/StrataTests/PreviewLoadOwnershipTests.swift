import AppKit
import Testing
@testable import StrataPreviews

@MainActor struct PreviewLoadOwnershipTests {
    @MainActor private final class Values { var applied: [String] = []; weak var view: PreviewView? }

    @Test func cancellingALoadKeepsTheNewRequestStartedByItsCancellationHandler() async throws {
        try await check { view, _ in view.cancelLoad() }
    }

    @Test func replacingALoadKeepsTheNewRequestStartedByItsCancellationHandler() async throws {
        try await check { view, applied in view.load({ "superseded" }, apply: applied) }
    }

    private func check(_ end: (PreviewView, @escaping (String) -> Void) -> Void) async throws {
        let view = PreviewView(frame: .zero), values = Values()
        values.view = view
        let (held, release) = AsyncStream<Void>.makeStream()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let operation = Task { for await _ in held {} }
        defer { release.finish() }
        view.load({
            await withTaskCancellationHandler {
                signal.yield(())
                await operation.value
                return "old"
            } onCancel: {
                MainActor.assumeIsolated {
                    values.view?.load({ "newest" }, apply: { values.applied.append($0) })
                }
            }
        }, apply: { values.applied.append($0) })
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let old = try #require(view.loadingTask)
        end(view) { values.applied.append($0) }
        let newest = try #require(view.loadingTask)
        #expect(newest != old && old.isCancelled)
        await newest.value
        release.finish()
        await old.value
        #expect(values.applied == ["newest"])
        #expect(view.loadingTask == nil && !view.isLoading)
    }
}

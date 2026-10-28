import AppKit
import Synchronization
import Testing
@testable import Strata

struct PreviewCancellationTests {
    private final class PasswordRequest {
        var pending: CheckedContinuation<String?, Never>?
        var cancelled = 0
        let started: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation

        init() { (started, signal) = AsyncStream<Void>.makeStream() }
        func request() async -> String? {
            guard pending == nil else { return nil }
            return await withCheckedContinuation { pending = $0; signal.yield(()) }
        }
        func answer(_ answer: String?) {
            let current = pending
            pending = nil
            current?.resume(returning: answer)
        }
        func cancel() {
            guard pending != nil else { return }
            cancelled += 1
            answer(nil)
        }
    }

    private func session(_ tree: TestTree, environment: PreviewEnvironment,
                         reader: @escaping PreviewArchiveAccess.Reader) async throws -> PreviewSession {
        let access = PreviewArchiveAccess(reader: reader)
        let session = PreviewSession(reader: environment.services.directories, archiveAccess: access)
        session.show(try #require(FileEntry(url: tree.url("pack.tar"))), showHidden: false, applications: .standard)
        await session.task?.value
        try #require(session.error == nil && session.roots.count == 2)
        return session
    }

    private func records(_ member: [String]?) -> [PreviewArchiveRecord] {
        ["a.txt", "ab.txt"].filter { member == nil || member == [$0] }.map {
            let body = Data($0.utf8)
            return PreviewArchiveRecord(path: [$0], kind: 1, size: Int64(body.count), modified: .distantPast,
                                        body: member == nil ? nil : body)
        }
    }

    @Test func archiveCancellationClearsThePasswordRequestBeforeReturningOrReplacingIt() async throws {
        for action in ["cancel", "selection", "command", "close"] {
            let tree = try TestTree("pack.tar", "outside/keep", "sibling")
            let environment = try PreviewEnvironment(tree), before = tree.snapshot()
            let prompt = PasswordRequest()
            let session = try await session(tree, environment: environment) { _, member, _, password in
                if member != nil, password == nil { throw PreviewArchiveError.password }
                return self.records(member)
            }
            session.archiveAccess.requestPassword = { _ in await prompt.request() }
            session.archiveAccess.cancelPassword = { prompt.cancel() }
            let content = PreviewArchiveContent(copies: environment.services.copies)
            var exported: PreviewArchiveLease?
            defer { prompt.cancel(); content.close(); session.close() }
            let item = try #require(session.roots.first { $0.name == "a.txt" })
            session.select(item)
            content.select(in: session)
            let first = try #require(content.task)
            var requests = prompt.started.makeAsyncIterator()
            _ = await requests.next()
            try #require(prompt.pending != nil)
            switch action {
            case "selection":
                let item = try #require(session.roots.first { $0.name == "ab.txt" })
                session.select(item)
                content.select(in: session)
            case "command":
                content.export(try #require(PreviewCommandTarget(session: session)), session: session) { exported = $0 }
            case "close": content.close()
            default: content.cancel()
            }
            try #require(prompt.pending == nil && prompt.cancelled == 1, "Password still owned after \(action)")
            if action == "selection" || action == "command" {
                _ = await requests.next()
                try #require(prompt.pending != nil)
                prompt.answer("accepted")
                await content.task?.value
                await content.commandTask?.value
                let chosen = try #require(exported ?? content.lease)
                #expect(try String(contentsOf: chosen.url, encoding: .utf8) == (action == "selection" ? "ab.txt" : "a.txt"))
            }
            await first.value
            content.close()
            exported = nil
            session.close()
            #expect(content.task == nil && content.commandTask == nil && content.error == nil)
            #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == before.filter { !$0.hasPrefix("environment/") })
            withExtendedLifetime(environment) {}
        }
    }

    nonisolated private final class CommandProbe: Sendable {
        struct State { var starts: [[String]] = []; var active = 0; var peak = 0 }
        private let state = Mutex(State())
        let first = PreviewReadGate<Void>()
        var starts: [[String]] { state.withLock { $0.starts } }
        var peak: Int { state.withLock { $0.peak } }
        func perform(_ paths: [String]) async throws {
            let count = state.withLock { state in
                state.starts.append(paths); state.active += 1; state.peak = max(state.peak, state.active)
                return state.starts.count
            }
            defer { state.withLock { $0.active -= 1 } }
            if count == 1 { try await first.read() }
        }
    }

    private func allowQueuedCommandsToStart() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @Test func replacementArchiveCommandsDrainThePreviousCommandBeforeReadingAgain() async throws {
        let tree = try TestTree("pack.tar", "outside/keep", "sibling")
        let environment = try PreviewEnvironment(tree), before = tree.snapshot(), probe = CommandProbe()
        let session = try await session(tree, environment: environment) { _, member, _, _ in
            if let member { try await probe.perform(member) }
            return self.records(member)
        }
        let content = PreviewArchiveContent(copies: environment.services.copies)
        defer { probe.first.finish(.failure(CancellationError())); content.close(); session.close() }
        let item = try #require(session.roots.first { $0.name == "a.txt" })
        session.select(item)
        let target = try #require(PreviewCommandTarget(session: session))
        var delivered: [PreviewArchiveLease] = []
        content.export(target, session: session) { delivered.append($0) }
        let first = try #require(content.commandTask)
        await probe.first.waitUntilStarted()
        content.export(target, session: session) { delivered.append($0) }
        let second = try #require(content.commandTask)
        content.export(target, session: session) { delivered.append($0) }
        let last = try #require(content.commandTask)
        await probe.first.waitUntilCancelled()
        await allowQueuedCommandsToStart()
        #expect(probe.starts == [["a.txt"]] && delivered.isEmpty)
        probe.first.finish(.success(()))
        await first.value; await second.value; await last.value
        #expect(probe.peak == 1 && probe.starts == [["a.txt"], ["a.txt"]] && delivered.count == 1)
        #expect(try String(contentsOf: #require(delivered.first).url, encoding: .utf8) == "a.txt")
        content.close(); delivered = []; session.close()
        #expect(TestTree.listing(of: environment.services.copies.clipboardRoot).isEmpty)
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == before.filter { !$0.hasPrefix("environment/") })
        withExtendedLifetime(environment) {}
    }

    nonisolated private final class Provider: CopyProvider, Sendable {
        let root: URL
        let probe: CommandProbe
        init(root: URL, probe: CommandProbe) { self.root = root; self.probe = probe }
        func contains(_ url: URL) -> Bool { url.path == root.path || url.path.hasPrefix(root.path + "/") }
        func isPlaceholder(_ url: URL) -> Bool { false }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { false }
        func fetch(_ urls: [URL]) async throws {}
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws { try await probe.perform(urls.map(\.path)) }
        func message(for error: Error, about url: URL) -> String { "fixture" }
        func displayPath(_ url: URL) -> String? { nil }
        func sourceName(_ url: URL) -> String? { nil }
    }

    @Test func replacementProviderCommandsDrainThePreviousCommandBeforePreparingAgain() async throws {
        let tree = try TestTree("copy/a/one.txt", "copy/ab/other.txt", "outside/keep")
        let probe = CommandProbe(), provider = Provider(root: tree.url("copy"), probe: probe)
        let environment = try PreviewEnvironment(tree, providers: [provider]), before = tree.snapshot()
        let session = PreviewSession(reader: environment.services.directories)
        session.show(try #require(FileEntry(url: tree.url("copy/a"))), showHidden: false, applications: .standard)
        await session.task?.value
        let content = PreviewProviderContent(copies: environment.services.copies)
        defer { probe.first.finish(.failure(CancellationError())); content.close(); session.close() }
        let target = try #require(PreviewCommandTarget(session: session))
        var delivered: [PreviewArchiveLease] = []
        content.perform(.copy, target: target, session: session) { _, lease in if let lease { delivered.append(lease) } }
        let first = try #require(content.commandTask)
        await probe.first.waitUntilStarted()
        content.perform(.copy, target: target, session: session) { _, lease in if let lease { delivered.append(lease) } }
        let second = try #require(content.commandTask)
        content.perform(.copy, target: target, session: session) { _, lease in if let lease { delivered.append(lease) } }
        let last = try #require(content.commandTask)
        await probe.first.waitUntilCancelled()
        await allowQueuedCommandsToStart()
        #expect(probe.starts == [[tree.url("copy/a").path]] && delivered.isEmpty)
        probe.first.finish(.success(()))
        await first.value; await second.value; await last.value
        #expect(probe.peak == 1 && probe.starts == [[tree.url("copy/a").path], [tree.url("copy/a").path]] && delivered.count == 1)
        #expect(TestTree.listing(of: try #require(delivered.first).url) == ["one.txt"])
        content.close(); delivered = []; session.close()
        #expect(TestTree.listing(of: environment.services.copies.clipboardRoot).isEmpty)
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == before.filter { !$0.hasPrefix("environment/") })
        withExtendedLifetime(environment) {}
    }
    @Test func replacementProviderCommandsKeepTheirSharedAutomaticReadAlive() async throws {
        let tree = try TestTree("copy/a.txt", "copy/ab.txt", "outside/keep")
        let gate = PreviewReadGate<Void>()
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["a.txt": Data("chosen".utf8)], gates: ["a.txt": gate])
        let environment = try PreviewEnvironment(tree, providers: [provider]), before = tree.snapshot()
        let session = PreviewSession(reader: environment.services.directories)
        session.show(try #require(FileEntry(url: tree.url("copy/a.txt"))), showHidden: false, applications: .standard)
        let content = PreviewProviderContent(copies: environment.services.copies)
        defer { gate.finish(.failure(CancellationError())); content.close(); session.close() }
        content.select(session)
        let read = try #require(content.task)
        await gate.waitUntilStarted()
        let target = try #require(PreviewCommandTarget(session: session))
        var delivered: [PreviewArchiveLease] = [], commands: [Task<Void, Never>] = []
        for _ in 0..<3 {
            content.perform(.copy, target: target, session: session) { _, lease in if let lease { delivered.append(lease) } }
            commands.append(try #require(content.commandTask))
        }
        #expect(!read.isCancelled)
        gate.finish(.success(()))
        await read.value
        for command in commands { await command.value }
        #expect(provider.fetched == [tree.url("copy/a.txt")] && delivered.count == 1)
        #expect(try String(contentsOf: #require(delivered.first).url, encoding: .utf8) == "chosen")
        content.close(); delivered = []; session.close()
        #expect(TestTree.listing(of: environment.services.copies.clipboardRoot).isEmpty)
        #expect(tree.text("copy/a.txt") == "chosen" && tree.text("copy/ab.txt") == "copy/ab.txt" && tree.text("outside/keep") == "outside/keep")
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == before.filter { !$0.hasPrefix("environment/") })
        withExtendedLifetime(environment) {}
    }

}

import Foundation
import Testing
import os
@testable import Strata

struct FinderLooksTests {
    private actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func open() {
            released = true
            waiting?.resume()
            waiting = nil
        }
    }

    @Test func aLateLookCannotRepopulateAFolderLeftBehind() async throws {
        let tree = try TestTree("first/", "second/")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let gate = Gate()
        let looks = FinderLooks { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 {
                signal.yield(())
                await gate.wait()
            }
            return FinderLook(name: "read \(call)")
        }
        looks.keep(only: [tree.url("first")])
        let old = Task { await looks.look(tree.url("first")) }
        for await _ in started { break }
        looks.keep(only: [tree.url("second")])
        await gate.open()
        #expect(await old.value.name == "read 1")
        looks.keep(only: [tree.url("first")])
        #expect(await looks.look(tree.url("first")).name == "read 2")
        #expect(calls.withLock { $0 } == 2)
        #expect(tree.snapshot() == ["first/", "second/"])
    }

    @Test(arguments: [false, true])
    func anOldReadCannotOverwriteAReopenedFoldersLook(oldFinishesFirst: Bool) async throws {
        let tree = try TestTree("folder/")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let oldGate = Gate(), newGate = Gate()
        let looks = FinderLooks { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call <= 2 {
                signal.yield(())
                await (call == 1 ? oldGate : newGate).wait()
            }
            return FinderLook(name: "read \(call)")
        }
        let folder = tree.url("folder")
        looks.keep(only: [folder])
        let old = Task { await looks.look(folder) }
        for await _ in started { break }
        looks.keep(only: [])
        looks.keep(only: [folder])
        let fresh = Task { await looks.look(folder) }
        for await _ in started { break }
        if oldFinishesFirst {
            await oldGate.open()
            _ = await old.value
            let (joining, joinSignal) = AsyncStream<Void>.makeStream()
            let joined = Task {
                joinSignal.yield(())
                return await looks.look(folder)
            }
            for await _ in joining { break }
            #expect(calls.withLock { $0 } == 2, "The old completion cannot clear the replacement still being read.")
            await newGate.open()
            #expect(await joined.value.name == "read 2")
        } else {
            await newGate.open()
            #expect(await fresh.value.name == "read 2")
            await oldGate.open()
        }
        #expect(await old.value.name == "read 1")
        #expect(await fresh.value.name == "read 2")
        #expect(await looks.look(folder).name == "read 2")
        #expect(calls.withLock { $0 } == 2)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func refreshesShareTheCurrentReadAndCancelledRequestsStartNoWork() async throws {
        let tree = try TestTree("folder/", "other/")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let gate = Gate()
        let looks = FinderLooks { _ in
            calls.withLock { $0 += 1 }
            signal.yield(())
            await gate.wait()
            return FinderLook(name: "Loaded")
        }
        let folder = tree.url("folder")
        looks.keep(only: [folder])
        let first = Task { await looks.look(folder) }
        for await _ in started { break }
        looks.keep(only: [folder])
        let (joining, joinSignal) = AsyncStream<Void>.makeStream()
        let second = Task {
            joinSignal.yield(())
            return await looks.look(folder)
        }
        for await _ in joining { break }
        let cancelled = Task { await looks.look(tree.url("other")) }
        cancelled.cancel()
        #expect(await cancelled.value.name == "other")
        await gate.open()
        #expect(await first.value.name == "Loaded")
        #expect(await second.value.name == "Loaded")
        #expect(await looks.look(folder).name == "Loaded")
        #expect(calls.withLock { $0 } == 1)
        #expect(tree.snapshot() == ["folder/", "other/"])
    }
}

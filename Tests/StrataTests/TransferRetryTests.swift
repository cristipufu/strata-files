import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

extension TransferTests {
    @Test func retriesLeaveReplacementsAndChangedParentsAlone() throws {
        for nested in [false, true] {
            for replacement in ["none", "file", "folder", "link", "link to an empty folder"] {
                let relative = nested ? "a/deeper/a.txt" : "a.txt"
                let name = nested ? "a" : "a.txt"
                let tree = try TestTree("from/" + relative, "from/ab.txt", "to/ab.txt", "outside/a.txt", "outside/keep", "empty/")
                let root = tree.url("to/" + name), broken = tree.url("to/" + relative)
                let location = Self.fixtureLocation(root)
                TransferEngine.hooks.beforeVerify = { url in
                    guard Self.fixtureLocation(url) == location else { return }
                    do { try Data("corrupted".utf8).write(to: broken) } catch { Issue.record(error) }
                }
                defer { TransferEngine.hooks = .init() }
                // The same paths in another tree must never activate this fixture's hook.
                let other = try TestTree("from/" + relative, "to/")
                let otherResult = TransferEngine.perform(0, TransferItem(source: other.url("from/" + name),
                    destination: other.url("to/" + name), operation: .copy), options: .init(verify: true, clone: false),
                    control: TransferControl(), progress: TransferProgress())
                #expect(otherResult.outcome == .done && other.text("to/" + relative) == "from/" + relative)
                let item = TransferItem(source: tree.url("from/" + name), destination: root, operation: .copy)
                let first = TransferEngine.perform(0, item, options: .init(verify: true, clone: false),
                                                   control: TransferControl(), progress: TransferProgress())
                TransferEngine.hooks = .init()
                #expect(first.outcome == .partial && first.failures.count == 1 && first.failures.first?.stage == .verify)
                #expect(!TransferEngine.exists(broken))
                let changed = nested ? tree.url("to/a/deeper") : broken
                if replacement != "none" {
                    if nested { try FileManager.default.moveItem(at: changed, to: tree.url("original")) }
                    switch replacement {
                    case "file": try Data("replacement".utf8).write(to: changed, options: .withoutOverwriting)
                    case "folder":
                        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
                        try Data("replacement".utf8).write(to: changed.appending(path: "a.txt"), options: .withoutOverwriting)
                    case "link":
                        try FileManager.default.createSymbolicLink(atPath: changed.path, withDestinationPath: tree.url("outside").path)
                    case "link to an empty folder":
                        // Nothing there to refuse an exclusive create: only the retry's own checks keep it out.
                        try FileManager.default.createSymbolicLink(atPath: changed.path, withDestinationPath: tree.url("empty").path)
                    default: break
                    }
                }
                let before = tree.snapshot()
                let texts = Dictionary(uniqueKeysWithValues: before.filter { !$0.hasSuffix("/") && !$0.contains(" -> ") }
                    .map { ($0, tree.text($0)) })
                let retry = TransferEngine.retry(0, item, landed: first.landed, failures: first.failures,
                    options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
                if replacement == "none" {
                    #expect(retry.outcome == .done && retry.failures.isEmpty)
                    #expect(tree.text("to/" + relative) == "from/" + relative)
                    #expect(tree.snapshot() == (before + ["to/" + relative]).sorted())
                } else {
                    #expect(retry.outcome == .partial && !retry.failures.isEmpty)
                    #expect(tree.snapshot() == before)
                }
                for (path, text) in texts { #expect(tree.text(path) == text, "\(nested), \(replacement), \(path)") }
                #expect(tree.text("outside/a.txt") == "outside/a.txt" && tree.text("outside/keep") == "outside/keep")
                withExtendedLifetime((tree, other)) {}
            }
        }
    }

    /// A failed part's place is the first attempt's only while what's there is what it left: nothing, or that item.
    @Test func aRetryTargetMatchesOnlyWhatTheFirstAttemptLeft() throws {
        let tree = try TestTree("to/a.txt", "to/ab.txt", "elsewhere/")
        let place = tree.url("to/a.txt")
        let left = try #require(TransferRetryTarget(place, identity: FileIdentity.read(place.path)))
        #expect(left.matches(place))
        // Another file in its place, or a link: not what it left.
        try FileManager.default.moveItem(at: place, to: tree.url("kept.txt"))
        try Data("other".utf8).write(to: place)
        #expect(!left.matches(place))
        try FileManager.default.removeItem(at: place)
        try FileManager.default.createSymbolicLink(at: place, withDestinationURL: tree.url("elsewhere"))
        #expect(!left.matches(place))
        // A place it left empty is its own while it's empty.
        try FileManager.default.removeItem(at: place)
        let emptied = try #require(TransferRetryTarget(place, identity: nil))
        #expect(emptied.matches(place))
        try Data("other".utf8).write(to: place)
        #expect(!emptied.matches(place))
        #expect(tree.snapshot() == ["elsewhere/", "kept.txt", "to/", "to/a.txt", "to/ab.txt"])
    }

    @Test func retriesRepairOnlyTheirRetainedPartialCopies() throws {
        for relative in ["a/deeper/a.txt", "a/deeper", "a"] {
            let directory = relative != "a/deeper/a.txt"
            for replaced in [false, true] {
                let tree = try TestTree("from/a/deeper/a.txt", "from/ab.txt", "to/ab.txt")
                let target = tree.url("to/" + relative)
                let location = tree.root.resolvingSymlinksInPath().appending(path: "to/" + relative).path
                TransferEngine.hooks.copyFailure = { url in
                    url.resolvingSymlinksInPath().path == location ? EIO : nil
                }
                defer { TransferEngine.hooks = .init() }
                let other = try TestTree("from/a/deeper/a.txt", "to/")
                let otherResult = TransferEngine.perform(0, TransferItem(source: other.url("from/a"),
                    destination: other.url("to/a"), operation: .copy), options: .init(verify: true, clone: false),
                    control: TransferControl(), progress: TransferProgress())
                #expect(otherResult.outcome == .done && other.text("to/a/deeper/a.txt") == "from/a/deeper/a.txt")
                let item = TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copy)
                let first = TransferEngine.perform(0, item, options: .init(verify: true, clone: false),
                    control: TransferControl(), progress: TransferProgress())
                TransferEngine.hooks = .init()
                #expect(first.outcome == .partial && first.failures.count == 1)
                let failure = try #require(first.failures.first)
                #expect(failure.stage == .copy)
                #expect(failure.retryTarget?.matches(target) == true, "directory=\(directory); captured=\(String(reflecting: failure.retryTarget)); now=\(String(reflecting: FileIdentity.read(target.path)))")
                #expect(tree.text("to/a/deeper/a.txt") == "from/a/deeper/a.txt")
                if replaced {
                    try FileManager.default.moveItem(at: target, to: tree.url("original"))
                    try Data("replacement".utf8).write(to: target, options: .withoutOverwriting)
                }
                let before = tree.snapshot()
                let retry = TransferEngine.retry(0, item, landed: first.landed, failures: first.failures,
                    options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
                #expect(tree.snapshot() == before)
                if replaced {
                    #expect(retry.outcome == .partial && retry.failures.count == 1)
                    #expect(tree.text("to/" + relative) == "replacement")
                    let again = TransferEngine.retry(0, item, landed: retry.landed, failures: retry.failures,
                        options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
                    #expect(again.outcome == .partial && tree.text("to/" + relative) == "replacement")
                    #expect(tree.snapshot() == before)
                } else {
                    #expect(retry.outcome == .done && retry.failures.isEmpty)
                    #expect(tree.text("to/a/deeper/a.txt") == "from/a/deeper/a.txt")
                }
                #expect(tree.text("to/ab.txt") == "to/ab.txt" && tree.text("from/ab.txt") == "from/ab.txt")
                #expect(tree.text("from/a/deeper/a.txt") == "from/a/deeper/a.txt")
                withExtendedLifetime((tree, other)) {}
            }
        }
    }

    @Test func retryingAFailedFolderRepairsItsNestedFailuresOnlyOnce() throws {
        let tree = try TestTree("from/a/deeper/a.txt", "from/ab.txt", "to/a/", "to/ab.txt")
        let root = tree.url("to/a")
        let folder = tree.url("to/a/deeper")
        let item = TransferItem(source: tree.url("from/a"), destination: root, operation: .copy)
        let parent = TransferFailure(item: 0, stage: .copy, source: tree.url("from/a/deeper"),
            destination: folder, message: "fixture", retryTarget: TransferRetryTarget(folder, identity: nil))
        let child = TransferFailure(item: 0, stage: .copy, source: tree.url("from/a/deeper/a.txt"),
            destination: tree.url("to/a/deeper/a.txt"), message: "fixture")
        let before = tree.snapshot()
        let result = TransferEngine.retry(0, item, landed: FileIdentity.read(root.path), failures: [child, parent, child, parent],
            options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
        #expect(result.outcome == .done && result.failures.isEmpty)
        #expect(tree.text("to/a/deeper/a.txt") == "from/a/deeper/a.txt")
        #expect(tree.text("to/ab.txt") == "to/ab.txt")
        #expect(tree.snapshot() == (before + ["to/a/deeper/", "to/a/deeper/a.txt"]).sorted())
    }


    @Test func retriesRequireTheOriginalRootEvenWhenTheImmediateParentSurvives() throws {
        let tree = try TestTree("from/a/deeper/a.txt", "to/a/deeper/", "to/ab.txt")
        let root = tree.url("to/a"), target = tree.url("to/a/deeper/a.txt")
        let ownership = try #require(FileIdentity.read(root.path))
        let failure = TransferFailure(item: 0, stage: .copy, source: tree.url("from/a/deeper/a.txt"),
            destination: target, message: "fixture", retryTarget: TransferRetryTarget(target, identity: nil))
        try FileManager.default.moveItem(at: root, to: tree.url("original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: tree.url("original/deeper"), to: tree.url("to/a/deeper"))
        #expect(failure.retryTarget?.matches(target) == true)
        let item = TransferItem(source: tree.url("from/a"), destination: root, operation: .copy)
        let before = tree.snapshot()
        let refused = TransferEngine.retry(0, item, landed: ownership, failures: [failure],
            options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
        #expect(refused.outcome == .partial && refused.failures.count == 1)
        #expect(tree.snapshot() == before)
        // Restoring the original root makes the original retry valid again, without accepting the replacement.
        try FileManager.default.moveItem(at: tree.url("to/a/deeper"), to: tree.url("original/deeper"))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: tree.url("original"), to: root)
        let restored = tree.snapshot()
        let repaired = TransferEngine.retry(0, item, landed: refused.landed, failures: refused.failures,
            options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
        #expect(repaired.outcome == .done && repaired.failures.isEmpty)
        #expect(tree.text("to/a/deeper/a.txt") == "from/a/deeper/a.txt")
        #expect(tree.text("to/ab.txt") == "to/ab.txt")
        #expect(tree.snapshot() == (restored + ["to/a/deeper/a.txt"]).sorted())
    }


    @Test func failedDirectoryCleanupKeepsItsOriginalDescriptorOwnership() throws {
        let tree = try TestTree("from/a/deeper/a.txt", "to/", "outside/keep.txt")
        let target = tree.url("to/a/deeper"), parked = tree.url("original"), outside = tree.url("outside")
        let location = tree.root.resolvingSymlinksInPath().appending(path: "to/a/deeper").path
        TransferEngine.hooks.copyFailure = { url in
            guard url.resolvingSymlinksInPath().path == location else { return nil }
            do {
                try FileManager.default.moveItem(at: url, to: parked)
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: outside.path)
            } catch { Issue.record(error) }
            return EIO
        }
        defer { TransferEngine.hooks = .init() }
        let other = try TestTree("from/a/deeper/a.txt", "to/")
        let otherResult = TransferEngine.perform(0, TransferItem(source: other.url("from/a"),
            destination: other.url("to/a"), operation: .copy), options: .init(verify: false, clone: false),
            control: TransferControl(), progress: TransferProgress())
        #expect(otherResult.outcome == .done && other.text("to/a/deeper/a.txt") == "from/a/deeper/a.txt")
        let item = TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copy)
        let first = TransferEngine.perform(0, item, options: .init(verify: true, clone: false),
            control: TransferControl(), progress: TransferProgress())
        TransferEngine.hooks = .init()
        #expect(first.outcome == .partial && first.failures.count == 1)
        #expect(first.failures.first?.retryTarget?.matches(target) == false)
        let before = tree.snapshot()
        let retry = TransferEngine.retry(0, item, landed: first.landed, failures: first.failures,
            options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
        #expect(retry.outcome == .partial && retry.failures.count == 1)
        #expect(tree.text("original/a.txt") == "from/a/deeper/a.txt")
        #expect(tree.text("outside/keep.txt") == "outside/keep.txt")
        #expect(tree.snapshot() == before)
        withExtendedLifetime((tree, other)) {}
    }

    @Test func verificationDetectsReplacedCopiesAndNeverDeletesUnownedReplacements() throws {
        let tree = try TestTree("from/a/deeper/a.txt", "from/a/keep.txt", "to/", "parked/")
        let root = tree.url("to/a"), target = tree.url("to/a/deeper/a.txt"), parked = tree.url("parked/landed.txt")
        let location = Self.fixtureLocation(root)
        TransferEngine.hooks.beforeVerify = { url in
            guard Self.fixtureLocation(url) == location else { return }
            do {
                try FileManager.default.moveItem(at: target, to: parked)
                // Same bytes as the source, but a different inode: verification must reject it and leave it alone.
                try Data("from/a/deeper/a.txt".utf8).write(to: target, options: .withoutOverwriting)
            } catch { Issue.record(error) }
        }
        defer { TransferEngine.hooks = .init() }
        let item = TransferItem(source: tree.url("from/a"), destination: root, operation: .copy)
        let first = TransferEngine.perform(0, item, options: .init(verify: true, clone: false),
            control: TransferControl(), progress: TransferProgress())
        TransferEngine.hooks = .init()
        #expect(first.outcome == .partial && first.failures.count == 1 && first.failures.first?.stage == .verify)
        // The unowned replacement at `target` was NOT deleted by verification cleanup, and retryTarget kept the landed inode.
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(first.failures.first?.retryTarget?.matches(target) == false)
        #expect(first.failures.first?.retryTarget?.createdIdentities(for: target, root: root, rootIdentity: first.landed)[target.path] == FileIdentity.read(parked.path))
        let beforeRetry = tree.snapshot()
        let refused = TransferEngine.retry(0, item, landed: first.landed, failures: first.failures,
            options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
        #expect(refused.outcome == .partial && refused.failures.count == 1)
        #expect(tree.snapshot() == beforeRetry)
        withExtendedLifetime(tree) {}
    }

    @Test func retryingAPartialDirectoryRepairsInPlaceAndPreservesUnownedChildren() throws {
        let tree = try TestTree("from/a/first.txt", "from/a/deeper/second.txt", "to/")
        let root = tree.url("to/a")
        let location = tree.root.resolvingSymlinksInPath().appending(path: "to/a").path
        TransferEngine.hooks.copyFailure = { url in
            url.resolvingSymlinksInPath().path == location ? EIO : nil
        }
        defer { TransferEngine.hooks = .init() }
        let item = TransferItem(source: tree.url("from/a"), destination: root, operation: .copy)
        let first = TransferEngine.perform(0, item, options: .init(verify: true, clone: false),
            control: TransferControl(), progress: TransferProgress())
        TransferEngine.hooks = .init()
        #expect(first.outcome == .partial && first.failures.count == 1)
        try FileManager.default.removeItem(at: tree.url("to/a/deeper/second.txt"))
        try Data("user note".utf8).write(to: tree.url("to/a/user-added.txt"), options: .withoutOverwriting)
        let repaired = TransferEngine.retry(0, item, landed: first.landed, failures: first.failures,
            options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
        #expect(repaired.outcome == .done && repaired.failures.isEmpty)
        #expect(tree.text("to/a/first.txt") == "from/a/first.txt")
        #expect(tree.text("to/a/deeper/second.txt") == "from/a/deeper/second.txt")
        #expect(tree.text("to/a/user-added.txt") == "user note")
        withExtendedLifetime(tree) {}
    }

    @Test func crossDiskMoveKeepsOriginalWhenDestinationOrSourceIdentityIsReplaced() throws {
        // 1. Replacing the destination after landing keeps the original source.
        let destSwapped = try TestTree("from/a.txt", "to/", "parked/")
        let destTarget = Self.fixtureLocation(destSwapped.url("to/a.txt"))
        let destParked = destSwapped.url("parked/landed.txt")
        TransferEngine.hooks.afterLanding = { url in
            guard Self.fixtureLocation(url) == destTarget else { return }
            try? FileManager.default.moveItem(at: url, to: destParked)
            try? Data("from/a.txt".utf8).write(to: url, options: .withoutOverwriting)
        }
        defer { TransferEngine.hooks = .init() }
        let destResult = TransferEngine.perform(0, TransferItem(source: destSwapped.url("from/a.txt"),
            destination: destSwapped.url("to/a.txt"), operation: .copyThenDelete),
            options: .init(verify: false, clone: false), control: TransferControl(), progress: TransferProgress())
        TransferEngine.hooks = .init()
        #expect(destResult.outcome != .done && !destResult.sourceRemoved)
        #expect(destSwapped.text("from/a.txt") == "from/a.txt")

        // 2. Replacing the source file with a different inode carrying identical size, time and bytes keeps it.
        let sourceSwapped = try TestTree("from/a/inner.txt", "to/", "parked/")
        let inner = sourceSwapped.url("from/a/inner.txt")
        let sourceParked = sourceSwapped.url("parked/original-inner.txt")
        let modified = (try FileManager.default.attributesOfItem(atPath: inner.path))[.modificationDate] as? Date
        let sourceTarget = Self.fixtureLocation(sourceSwapped.url("to/a"))
        TransferEngine.hooks.afterLanding = { url in
            guard Self.fixtureLocation(url) == sourceTarget else { return }
            try? FileManager.default.moveItem(at: inner, to: sourceParked)
            try? Data("from/a/inner.txt".utf8).write(to: inner, options: .withoutOverwriting)
            if let modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: inner.path)
            }
        }
        let sourceResult = TransferEngine.perform(0, TransferItem(source: sourceSwapped.url("from/a"),
            destination: sourceSwapped.url("to/a"), operation: .copyThenDelete),
            options: .init(verify: true, clone: false), control: TransferControl(), progress: TransferProgress())
        TransferEngine.hooks = .init()
        #expect(sourceResult.outcome != .done && !sourceResult.sourceRemoved)
        #expect(sourceSwapped.text("from/a/inner.txt") == "from/a/inner.txt")
        withExtendedLifetime((destSwapped, sourceSwapped)) {}
    }

}

import Foundation
import Synchronization
import Testing
@testable import Strata

struct ScratchVolumeTests {
    @Test func onlyDisksThatEndedProcessesLeftAreSwept() async throws {
        let tree = try TestTree("strata-volume-ended/", "strata-volume-ended/disk.sparseimage", "strata-volume-ended/dmg.ABC/",
                                "target/",
                                "strata-volume-running/", "strata-volume-running/disk.sparseimage",
                                "strata-volume-unmarked/", "strata-volume-unmarked/disk.sparseimage",
                                "strata-volume-holding/", "strata-volume-holding/disk.sparseimage", "strata-volume-holding/kept",
                                "strata-volume-filled/", "strata-volume-filled/disk.sparseimage", "strata-volume-filled/dmg.XYZ/",
                                "strata-volume-filled/dmg.XYZ/kept",
                                "strata-volume-linked/", "strata-volume-linked/disk.sparseimage",
                                "strata-volume-linked/dmg.empty -> ../target",
                                "strata-volume-attached/", "strata-volume-attached/disk.sparseimage",
                                "strata-volume-mixed/", "strata-volume-mixed/disk.sparseimage", "strata-volume-mixed/dmg.A/",
                                "strata-volume-mixed/dmg.B/", "strata-volume-mixed/dmg.B/kept",
                                "strata-volume-odd/", "strata-volume-odd/disk.sparseimage/", "strata-volume-odd/dmg.A/",
                                "other/", "other/disk.sparseimage")
        let current = try #require(RunOwner.current)
        // The same process number, started at another time: a process that ended and whose number was given again.
        let ended = RunOwner(pid: current.pid, started: current.started - 1)
        let owners = ["strata-volume-ended": ended, "strata-volume-running": current, "strata-volume-holding": ended,
                      "strata-volume-filled": ended, "strata-volume-linked": ended, "strata-volume-attached": ended,
                      "strata-volume-mixed": ended, "strata-volume-odd": ended, "other": ended]
        for (folder, owner) in owners {
            try owner.marker.write(to: tree.url(folder).appending(path: RunOwner.file))
        }
        let root = tree.root, attached = tree.url("strata-volume-attached/disk.sparseimage").path
        let problems = try await TestWork.run { ScratchVolume.sweep(in: root, attached: { [attached] }) }
        #expect(problems.count == 6)
        #expect(problems.contains { $0.hasSuffix("strata-volume-holding, which holds kept") })
        #expect(problems.contains { $0.hasSuffix("strata-volume-filled, which holds dmg.XYZ") })
        // A folder is checked whole before anything in it is removed.
        #expect(problems.contains { $0.hasSuffix("strata-volume-mixed, which holds dmg.B") })
        #expect(problems.contains { $0.hasSuffix("strata-volume-odd, which holds disk.sparseimage") })
        // A link to an empty folder, named like a mount folder, isn't one to remove.
        #expect(problems.contains { $0.hasSuffix("strata-volume-linked, which holds dmg.empty") })
        #expect(problems.contains { $0.hasSuffix("\(attached) is attached but not mounted there") })
        // Only the ended process's folder is gone; every other one keeps everything it held.
        #expect(tree.snapshot() == ["other/", "other/disk.sparseimage", "other/owner",
                                    "strata-volume-attached/", "strata-volume-attached/disk.sparseimage",
                                    "strata-volume-attached/owner",
                                    "strata-volume-filled/", "strata-volume-filled/disk.sparseimage", "strata-volume-filled/dmg.XYZ/",
                                    "strata-volume-filled/dmg.XYZ/kept", "strata-volume-filled/owner",
                                    "strata-volume-holding/", "strata-volume-holding/disk.sparseimage",
                                    "strata-volume-holding/kept", "strata-volume-holding/owner",
                                    "strata-volume-linked/", "strata-volume-linked/disk.sparseimage",
                                    "strata-volume-linked/dmg.empty -> ../target", "strata-volume-linked/owner",
                                    "strata-volume-mixed/", "strata-volume-mixed/disk.sparseimage", "strata-volume-mixed/dmg.A/",
                                    "strata-volume-mixed/dmg.B/", "strata-volume-mixed/dmg.B/kept", "strata-volume-mixed/owner",
                                    "strata-volume-odd/", "strata-volume-odd/disk.sparseimage/", "strata-volume-odd/dmg.A/",
                                    "strata-volume-odd/owner",
                                    "strata-volume-running/", "strata-volume-running/disk.sparseimage",
                                    "strata-volume-running/owner",
                                    "strata-volume-unmarked/", "strata-volume-unmarked/disk.sparseimage", "target/"])
    }

    @Test func aDiskMountedInAnEndedProcesssFolderIsDetachedAndARunningOnesIsLeft() async throws {
        let tree = try TestTree("strata-volume-ended/", "strata-volume-running/", "strata-volume-linked/")
        let current = try #require(RunOwner.current)
        let ended = RunOwner(pid: current.pid, started: current.started - 1)
        for (folder, owner) in ["strata-volume-ended": ended, "strata-volume-running": current, "strata-volume-linked": ended] {
            try owner.marker.write(to: tree.url(folder).appending(path: RunOwner.file))
        }
        let root = tree.root
        let cleanup = Mutex<[String]>([])
        let (problems, attached, mount, device, left) = try await TestWork.run {
            () -> ([String], [String], String, String?, [String]) in
            let folders = ["strata-volume-ended", "strata-volume-running"].map { root.appending(path: $0) }
            // This test's own images, whatever happened, mounted or not.
            defer {
                let problems = folders.compactMap { folder -> String? in
                    do {
                        try ScratchVolume.detach(image: folder.appending(path: "disk.sparseimage").path)
                        return nil
                    } catch {
                        return "\(error)"
                    }
                }
                cleanup.withLock { $0 = problems }
            }
            // Attached as ScratchVolume attaches its disks.
            for folder in folders {
                try ScratchVolume.hdiutil(["create", "-size", "64m", "-fs", "APFS", "-volname", "StrataSweep", "-type", "SPARSE",
                                           folder.appending(path: "disk").path])
                try ScratchVolume.hdiutil(["attach", folder.appending(path: "disk.sparseimage").path, "-nobrowse",
                                           "-mountrandom", folder.path])
            }
            // An ended process's folder whose mount folder is a link to the running one's disk.
            let mount = try #require(try FileManager.default.contentsOfDirectory(atPath: folders[1].path).first { $0.hasPrefix("dmg.") })
            try FileManager.default.createSymbolicLink(atPath: root.appending(path: "strata-volume-linked/dmg.link").path,
                                                       withDestinationPath: folders[1].appending(path: mount).path)
            let problems = ScratchVolume.sweep(in: root)
            let ours = { (paths: [String]) in paths.filter { $0.contains(root.lastPathComponent) } }
            let attached = ours(try ScratchVolume.attachedImagePaths())
            // The running disk detaches by the whole disk its image's path names.
            let image = folders[1].appending(path: "disk.sparseimage").path
            let device = ScratchVolume.wholeDisk(of: image, in: try ScratchVolume.attachedImages())
            try ScratchVolume.detach(image: image)
            let left = ours(try ScratchVolume.attachedImagePaths())
            return (problems, attached, mount, device, left)
        }
        // The disk mounted in the ended folder is detached and the folder removed; the running one's disk is never
        // reached through a link, and the folder holding the link is left.
        #expect(cleanup.withLock { $0 }.isEmpty)
        #expect(problems.count == 1 && problems.allSatisfy { $0.hasSuffix("strata-volume-linked, which holds dmg.link") })
        #expect(attached.count == 1 && attached.allSatisfy { $0.hasSuffix("strata-volume-running/disk.sparseimage") })
        #expect(device != nil && left.isEmpty)
        #expect(tree.snapshot() == ["strata-volume-linked/", "strata-volume-linked/dmg.link -> strata-volume-running/\(mount)",
                                    "strata-volume-linked/owner", "strata-volume-running/",
                                    "strata-volume-running/disk.sparseimage", "strata-volume-running/owner"])
    }

    @Test func anImagesOwnDiskIsChosenNotItsContainerOrASlice() {
        let images: [[String: Any]] = [
            ["image-path": "/var/folders/x/T/strata-volume-B/disk.sparseimage",
             "system-entities": [["dev-entry": "/dev/disk4", "content-hint": "GUID_partition_scheme"]]],
            // The container the system made from the image, and the slices, listed before the image's own disk.
            ["image-path": "/var/folders/x/T/strata-volume-A/disk.sparseimage",
             "system-entities": [["dev-entry": "/dev/disk7", "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC"],
                                 ["dev-entry": "/dev/disk7s1", "content-hint": "41504653-0000-11AA-AA11-00306543ECAC"],
                                 ["dev-entry": "/dev/disk6s1", "content-hint": "7C3457EF-0000-11AA-AA11-00306543ECAC"],
                                 ["dev-entry": "/dev/disk", "content-hint": "GUID_partition_scheme"],
                                 ["dev-entry": "/dev/disk6", "content-hint": "GUID_partition_scheme"]]],
        ]
        #expect(ScratchVolume.wholeDisk(of: "/private/var/folders/x/T/strata-volume-A/disk.sparseimage", in: images) == "/dev/disk6")
        #expect(ScratchVolume.wholeDisk(of: "/var/folders/x/T/strata-volume-C/disk.sparseimage", in: images) == nil)
    }

    @Test func aBusyDiskIsTriedAgainAndWhatToDetachIsAskedAfreshEachTime() {
        struct Unlisted: Error {}
        let busy = ScratchVolume.HdiutilFailure(description: "Resource busy", status: EBUSY)
        let refused = ScratchVolume.HdiutilFailure(description: "No such file or directory", status: ENOENT)
        /// Detaches what `targets` name in turn (nil once there's nothing left) while hdiutil fails as `failures` say.
        func detach(_ targets: [Result<String?, Error>], failing failures: [ScratchVolume.HdiutilFailure],
                    retries: Int = 4) -> (detached: [String], pauses: Int, failure: Error?, unread: Int) {
            var targets = targets, failures = failures, detached: [String] = [], pauses = 0, failure: Error?
            let run: ([String]) throws -> Data = { arguments in
                #expect(arguments.first == "detach" && arguments.last == "-force" && arguments.count == 3)
                detached.append(arguments[1])
                if !failures.isEmpty { throw failures.removeFirst() }
                return Data()
            }
            do {
                try ScratchVolume.detach(retries: retries, pause: { pauses += 1 }, run: run) {
                    try (targets.isEmpty ? .failure(Unlisted()) : targets.removeFirst()).get()
                }
            } catch {
                failure = error
            }
            return (detached, pauses, failure, targets.count)
        }
        func status(_ error: Error?) -> Int32? { (error as? ScratchVolume.HdiutilFailure)?.status }
        // Busy, then free under another device name: each try detaches what's there then.
        let moved = detach([.success("/dev/disk9"), .success("/dev/disk12")], failing: [busy])
        #expect(moved.detached == ["/dev/disk9", "/dev/disk12"])
        #expect(moved.pauses == 1 && moved.failure == nil && moved.unread == 0)
        // A disk that went anyway after saying it was busy isn't followed to whatever took its device's name, even
        // after the last try.
        let gone = detach([.success("/dev/disk9"), .success(nil), .success("/dev/disk9")], failing: [busy])
        #expect(gone.detached == ["/dev/disk9"])
        #expect(gone.pauses == 1 && gone.failure == nil && gone.unread == 1)
        let late = detach([.success("/dev/disk9"), .success("/dev/disk9"), .success(nil)], failing: [busy, busy],
                          retries: 1)
        #expect(late.detached == ["/dev/disk9", "/dev/disk9"])
        #expect(late.pauses == 2 && late.failure == nil && late.unread == 0)
        // One that stays busy fails with what its last detach said.
        let stuck = detach(Array(repeating: .success("/dev/disk9"), count: 4), failing: [busy, busy, busy], retries: 2)
        #expect(stuck.detached == ["/dev/disk9", "/dev/disk9", "/dev/disk9"])
        #expect(stuck.pauses == 3 && status(stuck.failure) == EBUSY && stuck.unread == 0)
        // Anything but busy fails at once, unless nothing is left by then; a look that fails after a busy disk keeps
        // why it was busy.
        let lasting = detach(Array(repeating: .success("/dev/disk9"), count: 3), failing: [refused])
        #expect(lasting.detached == ["/dev/disk9"])
        #expect(lasting.pauses == 0 && status(lasting.failure) == ENOENT && lasting.unread == 1)
        let refusedLater = detach(Array(repeating: .success("/dev/disk9"), count: 3), failing: [busy, refused])
        #expect(refusedLater.detached == ["/dev/disk9", "/dev/disk9"])
        #expect(refusedLater.pauses == 1 && status(refusedLater.failure) == ENOENT && refusedLater.unread == 0)
        let forgiven = detach([.success("/dev/disk9"), .success(nil)], failing: [refused])
        #expect(forgiven.detached == ["/dev/disk9"])
        #expect(forgiven.pauses == 0 && forgiven.failure == nil && forgiven.unread == 0)
        let unlisted = detach([.success("/dev/disk9"), .failure(Unlisted())], failing: [busy])
        #expect(unlisted.detached == ["/dev/disk9"])
        #expect(unlisted.pauses == 1 && status(unlisted.failure) == EBUSY && unlisted.unread == 0)
        // Nothing to detach is nothing to do.
        let none = detach([.success(nil)], failing: [], retries: 0)
        #expect(none.detached.isEmpty && none.pauses == 0 && none.failure == nil && none.unread == 0)
    }

    @Test func aFailingHdiutilSaysWhy() async throws {
        let tree = try TestTree("empty/")
        let image = tree.url("empty/disk.sparseimage").path
        let failure = await #expect(throws: ScratchVolume.HdiutilFailure.self) {
            try await TestWork.run { try ScratchVolume.hdiutil(["attach", image, "-nobrowse"]) }
        }
        // hdiutil's own words follow its exit status.
        let said = failure?.description.components(separatedBy: ": ").dropFirst().joined(separator: ": ") ?? ""
        #expect(failure?.description.hasPrefix("hdiutil attach exited with ") == true && !said.isEmpty)
        // Its exit status says whether trying again could help.
        let status = try #require(failure?.status)
        #expect(failure?.description.hasPrefix("hdiutil attach exited with \(status): ") == true && status != 0)
        #expect(tree.snapshot() == ["empty/"])
        // A signal's number is no exit status.
        let stopped = ScratchVolume.HdiutilFailure("detach", ended: .uncaughtSignal, status: SIGTERM, saying: "")
        #expect(stopped.status == nil && stopped.description == "hdiutil detach was stopped by signal \(SIGTERM)")
    }
}

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
            defer { cleanup.withLock { $0 = folders.flatMap(Self.detachEverything) } }
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
            let device = ScratchVolume.wholeDisk(of: folders[1].appending(path: "disk.sparseimage").path,
                                                 in: try ScratchVolume.attachedImages())
            if let device { try ScratchVolume.hdiutil(["detach", device, "-force"]) }
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

    /// Detaches whatever is mounted in `folder`, so a test leaves no disk behind whatever happened; what it couldn't.
    nonisolated private static func detachEverything(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("dmg.") }.compactMap { name in
            let mount = folder.appending(path: name).path
            var mounted = stat(), parent = stat()
            guard lstat(mount, &mounted) == 0, lstat(folder.path, &parent) == 0, mounted.st_dev != parent.st_dev else { return nil }
            do {
                try ScratchVolume.hdiutil(["detach", mount, "-force"])
                return nil
            } catch {
                return "\(error)"
            }
        }
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

    @Test func aFailingHdiutilSaysWhy() async throws {
        let tree = try TestTree("empty/")
        let image = tree.url("empty/disk.sparseimage").path
        let failure = await #expect(throws: ScratchVolume.HdiutilFailure.self) {
            try await TestWork.run { try ScratchVolume.hdiutil(["attach", image, "-nobrowse"]) }
        }
        // hdiutil's own words follow its exit status.
        let said = failure?.description.components(separatedBy: ": ").dropFirst().joined(separator: ": ") ?? ""
        #expect(failure?.description.hasPrefix("hdiutil attach exited with ") == true && !said.isEmpty)
        #expect(tree.snapshot() == ["empty/"])
    }
}

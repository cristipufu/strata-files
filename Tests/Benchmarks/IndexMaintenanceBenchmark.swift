import Foundation
import Darwin

@main enum IndexMaintenanceBenchmark {
    static func main() {
        allocationUpdates()
        projectClassification()
    }

    private static func allocationUpdates() {
        for count in [5_000, 10_000, 20_000] {
            let store = IndexStore()
            store.write { s in
                let root = s.addRoot(path: "/synthetic", mtime: 0)
                var names: [UInt8] = [], items: [ScannedItem] = []
                for i in 0..<count {
                    let name = Array("folder-\(i)".utf8)
                    items.append(ScannedItem(nameOffset: names.count, nameLength: name.count, isDirectory: true,
                        isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 0))
                    names += name
                }
                let ids = names.withUnsafeBytes { s.appendChildren(items, nameBuffer: $0, of: root) }
                _ = s.finishedAllocationRead(of: root)
                let before = cpu()
                for id in ids.reversed() { _ = s.finishedAllocationRead(of: id) }
                let seconds = cpu() - before
                guard s.allocatedSize(root) == 0 else { fail("Incomplete allocation totals") }
                print("folders=\(count) cpu_seconds=\(seconds) allocation_known=\(s.allocatedSize(root) != nil)")
            }
        }
    }

    private static func projectClassification() {
        for count in [2_000, 4_000, 8_000] {
            var names: [UInt8] = [], items: [ScannedItem] = []
            for i in 0..<(count * 2) {
                let directory = i >= count
                let name = Array((directory ? "source-\(i)" : "project-\(i).csproj").utf8)
                items.append(ScannedItem(nameOffset: names.count, nameLength: name.count, isDirectory: directory,
                    isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 0))
                names += name
            }
            let before = cpu()
            let results = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
            let seconds = cpu() - before
            guard results.allSatisfy({ !$0 }) else { fail("Source folders were classified as build output") }
            print("markers=\(count) folders=\(count) cpu_seconds=\(seconds) noise_count=\(results.filter { $0 }.count)")
        }
    }
    private static func cpu() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { fail("Could not measure CPU time") }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

}

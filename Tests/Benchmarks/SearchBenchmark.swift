import Foundation
import Darwin

@main struct SearchBenchmark {
    static func main() async {
        let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1_000_000
        guard (10_000...3_000_000).contains(count) else { fputs("Use 10000...3000000 synthetic entries\n", stderr); exit(1) }
        await run(count)
    }

    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    nonisolated static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @concurrent static func run(_ count: Int) async {
        let index = IndexStore()
        index.write { store in
            store.reserve(entries: count + 10)
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            func folder(_ name: String, parent: Int32) -> Int32 {
                let bytes = Array(name.utf8)
                let item = ScannedItem(nameOffset: 0, nameLength: bytes.count, isDirectory: true, isPackage: false,
                    isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 0)
                return bytes.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: parent).lowerBound }
            }
            let github = folder("GitHub", parent: root)
            let project = folder("strata", parent: github)
            let sources = folder("Sources", parent: project)
            let cache = folder("Library", parent: root)
            store.flags[Int(cache)] |= IndexStore.Flag.noise | IndexStore.Flag.hidden
            for batch in stride(from: 0, to: count, by: 1000) {
                var names = Data(), items: [ScannedItem] = []
                for number in batch..<min(batch + 1000, count) {
                    let name = Data("file-\(number).\(number % 10 == 0 ? "zip" : "txt")".utf8)
                    items.append(ScannedItem(nameOffset: names.count, nameLength: name.count, isDirectory: false,
                        isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false, size: 1, mtime: 0))
                    names.append(name)
                }
                _ = names.withUnsafeBytes { store.appendChildren(items, nameBuffer: $0, of: batch < count * 7 / 10 ? cache : sources) }
            }
        }
        for pass in 0..<3 {
            for text in [".", ".zip", "github/strata/sources"] {
                for all in [false, true] {
                    var query = IndexQuery.parse(text)
                    if all { query.includeNoise = true; query.includeHidden = true }
                    let before = footprint(), cpuBefore = cpu(), start = ContinuousClock.now
                    let result = IndexSearch.run(query, in: index, limit: 30)
                    let elapsed = start.duration(to: .now).components
                    let row: [String: Any] = ["pass": pass, "entries": count, "query": text, "all_entries": all,
                        "total": result.total, "shown": result.hits.count, "elapsed_ms": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                        "cpu_ms": (cpu() - cpuBefore) * 1000, "before_bytes": before, "after_bytes": footprint()]
                    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                        FileHandle.standardOutput.write(data + Data("\n".utf8))
                    }
                }
            }
        }
    }
}

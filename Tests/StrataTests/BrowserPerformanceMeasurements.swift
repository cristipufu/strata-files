import AppKit
import Darwin
import Testing
@testable import Strata
@testable import StrataModel

/// Opt-in measurements, separate from correctness tests and without touching an installed app.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STRATA_BROWSER_BENCHMARK"] == "1"))
@MainActor struct BrowserPerformanceMeasurements {
    nonisolated private struct Sample: Codable, Sendable {
        let mode: String
        let iteration: Int
        let viewportPixelWidth: Int
        let viewportPixelHeight: Int
        let firstNativeFrameMilliseconds: Double
        let firstLoadedEntryCount: Int
        let completeFolderMilliseconds: Double
        let scrollFrameMilliseconds: [Double]
        let mainActorDelayMilliseconds: [Double]
        let idleCPUPercentOfOneCore: Double
        let startingFootprintBytes: UInt64
        let endingFootprintBytes: UInt64
        let processPeakResidentBytes: Int64
    }
    nonisolated private struct Report: Codable, Sendable {
        let commit: String
        let configuration: String
        let os: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
        let thermalState: Int
        let lowPowerMode: Bool
        let entries: Int
        let samples: [Sample]
    }

    nonisolated private struct ReorderReport: Codable, Sendable {
        let commit: String
        let configuration: String
        let os: String
        let processorCount: Int
        let thermalState: Int
        let lowPowerMode: Bool
        let entries: Int
        let milliseconds: [Double]
    }

    @Test func measureNativeMetadataReordering() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard variables["STRATA_BENCHMARK_SCENARIO"] == "resort" else { return }
        let count = Int(variables["STRATA_BENCHMARK_ENTRIES"] ?? "") ?? 10_000
        let repetitions = Int(variables["STRATA_BENCHMARK_REPETITIONS"] ?? "") ?? 3
        try #require((100...100_000).contains(count) && (1...10).contains(repetitions))
        let destination = try #require(variables["STRATA_BENCHMARK_REPORT"])
        let tree = try TestTree()
        try await Self.seed(tree.root, count: count)
        var measurements: [Double] = []
        for _ in 0..<repetitions {
            let environment = try IndependentEnvironment()
            environment.preferences.viewMode = BrowserViewMode.list.rawValue
            let browser = BrowserViewController(services: environment.services)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = browser
            browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            defer { browser.stopBackgroundWork(); window.contentViewController = nil; window.close(); withExtendedLifetime(environment) {} }
            browser.load(tree.root)
            await browser.directoryReads.task?.value
            await environment.services.tags.settled()
            try #require(browser.visibleRows.count == count)
            let bitmap = try #require(browser.view.bitmapImageRepForCachingDisplay(in: browser.view.bounds))
            try draw(browser, bitmap: bitmap)
            let selected = browser.visibleRows[count / 2].url
            browser.select([selected], scroll: false)
            browser.ordering.choose(.init(key: .name, ascending: false), remember: false)
            let start = ContinuousClock.now
            browser.resortAfterMetadata()
            try draw(browser, bitmap: bitmap)
            measurements.append(Self.milliseconds(since: start))
            #expect(browser.selectedURLs == [selected])
            for index in [0, count / 2, count - 1] {
                #expect((browser.outlineView.item(atRow: index) as? FileNode) === browser.visibleRows[index])
            }
        }
        let process = ProcessInfo.processInfo
        try await Self.save(ReorderReport(commit: variables["STRATA_BENCHMARK_COMMIT"] ?? "unknown",
            configuration: variables["STRATA_BENCHMARK_CONFIGURATION"] ?? "unknown", os: process.operatingSystemVersionString,
            processorCount: process.processorCount, thermalState: process.thermalState.rawValue,
            lowPowerMode: process.isLowPowerModeEnabled, entries: count,
            milliseconds: measurements), to: URL(filePath: destination))
    }

    @Test func measureNativeDirectoryRenderingAndScrolling() async throws {
        let variables = ProcessInfo.processInfo.environment
        let count = Int(variables["STRATA_BENCHMARK_ENTRIES"] ?? "") ?? 10_000
        let repetitions = Int(variables["STRATA_BENCHMARK_REPETITIONS"] ?? "") ?? 3
        try #require((100...100_000).contains(count) && (1...10).contains(repetitions))
        let destination = try #require(variables["STRATA_BENCHMARK_REPORT"])
        let tree = try TestTree()
        try await Self.seed(tree.root, count: count)
        var samples: [Sample] = []
        for mode in [BrowserViewMode.list, .grid] {
            for iteration in 1...repetitions {
                samples.append(try await measure(tree.root, count: count, mode: mode, iteration: iteration))
            }
        }
        let process = ProcessInfo.processInfo
        let report = Report(commit: variables["STRATA_BENCHMARK_COMMIT"] ?? "unknown",
            configuration: variables["STRATA_BENCHMARK_CONFIGURATION"] ?? "unknown", os: process.operatingSystemVersionString,
            processorCount: process.processorCount, physicalMemoryBytes: process.physicalMemory,
            thermalState: process.thermalState.rawValue, lowPowerMode: process.isLowPowerModeEnabled, entries: count, samples: samples)
        try await Self.save(report, to: URL(filePath: destination))
    }

    private func measure(_ folder: URL, count: Int, mode: BrowserViewMode, iteration: Int) async throws -> Sample {
        let environment = try IndependentEnvironment()
        environment.preferences.viewMode = mode.rawValue
        let browser = BrowserViewController(services: environment.services)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; window.close(); withExtendedLifetime(environment) {} }
        browser.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(browser.view.bitmapImageRepForCachingDisplay(in: browser.view.bounds))
        let heartbeat = MainActorHeartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        await Task.yield()
        let memoryBefore = try Self.footprint(), start = ContinuousClock.now
        var firstFrame: Double?, firstCount = 0
        let observer = BrowserContentObserver { browser in
            guard firstFrame == nil, !browser.visibleRows.isEmpty else { return }
            do {
                try draw(browser, bitmap: bitmap)
                firstFrame = Self.milliseconds(since: start)
                firstCount = browser.visibleRows.count
            } catch { Issue.record(error) }
        }
        browser.delegate = observer
        browser.load(folder)
        await browser.directoryReads.task?.value
        try #require(browser.visibleRows.count == count)
        try draw(browser, bitmap: bitmap)
        let completeFrame = Self.milliseconds(since: start)
        withExtendedLifetime(observer) {}
        let scroll = try #require(mode == .list ? browser.outlineScrollView : browser.gridController?.collectionView.enclosingScrollView)
        let scrolling = try await measureScrolling(scroll, browser: browser, bitmap: bitmap)
        heartbeat.stop()
        let cpu = try await idleCPU()
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        return Sample(mode: mode == .list ? "list" : "icons", iteration: iteration,
            viewportPixelWidth: bitmap.pixelsWide, viewportPixelHeight: bitmap.pixelsHigh, firstNativeFrameMilliseconds: firstFrame ?? completeFrame,
            firstLoadedEntryCount: firstCount, completeFolderMilliseconds: completeFrame,
            scrollFrameMilliseconds: scrolling, mainActorDelayMilliseconds: heartbeat.delays, idleCPUPercentOfOneCore: cpu,
            startingFootprintBytes: memoryBefore, endingFootprintBytes: try Self.footprint(), processPeakResidentBytes: Int64(usage.ru_maxrss))
    }

    private func measureScrolling(_ scroll: NSScrollView, browser: BrowserViewController, bitmap: NSBitmapImageRep) async throws -> [Double] {
        let clip = scroll.contentView
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
        var scrolling: [Double] = []
        for step in 0..<60 {
            let fraction = CGFloat(step < 30 ? step : 59 - step) / 29
            let start = ContinuousClock.now
            clip.scroll(to: NSPoint(x: 0, y: maximum * fraction))
            scroll.reflectScrolledClipView(clip)
            try draw(browser, bitmap: bitmap)
            scrolling.append(Self.milliseconds(since: start))
            try await Task.sleep(for: .milliseconds(16))
        }
        return scrolling
    }

    private func idleCPU() async throws -> Double {
        try await Task.sleep(for: .milliseconds(500))
        let cpuBefore = Self.cpuSeconds(), idleStart = ContinuousClock.now
        try await Task.sleep(for: .seconds(2))
        return (Self.cpuSeconds() - cpuBefore) / (Self.milliseconds(since: idleStart) / 1000) * 100
    }

    private func draw(_ browser: BrowserViewController, bitmap: NSBitmapImageRep) throws {
        browser.view.layoutSubtreeIfNeeded()
        if browser.effectiveMode == .list {
            let row = browser.outlineView.rows(in: browser.outlineView.visibleRect).location
            try #require(row != NSNotFound && browser.outlineView.rowView(atRow: row, makeIfNecessary: true) != nil)
        } else { try #require(browser.gridController?.collectionView.visibleItems().isEmpty == false) }
        browser.view.cacheDisplay(in: browser.view.bounds, to: bitmap)
    }

    nonisolated private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
    nonisolated private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    nonisolated private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw CocoaError(.fileReadUnknown) }
        return info.phys_footprint
    }
    @concurrent private static func seed(_ folder: URL, count: Int) async throws {
        for index in 0..<count {
            try Task.checkCancellation()
            let name = String(format: "Entry-%06d", index)
            if index % 20 == 0 { try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: false) }
            else { try Data("Synthetic benchmark file.\n".utf8).write(to: folder.appending(path: name + ".txt")) }
        }
    }
    @concurrent private static func save<T: Encodable & Sendable>(_ report: T, to url: URL) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}

@MainActor private final class MainActorHeartbeat {
    private(set) var delays: [Double] = []
    private var task: Task<Void, Never>?

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                let due = ContinuousClock.now + .milliseconds(16)
                do { try await Task.sleep(until: due) } catch { return }
                let late = (ContinuousClock.now - due).components
                self?.delays.append(max(0, Double(late.seconds) * 1000 + Double(late.attoseconds) / 1e15))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    isolated deinit { task?.cancel() }
}

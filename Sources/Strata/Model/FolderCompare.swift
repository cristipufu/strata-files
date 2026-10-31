import Foundation

/// Compare with Other Pane: what differs between two folder trees, by relative path. Only the topmost item missing on
/// one side is listed (a missing folder, not everything in it); files compare by modification date (2 s apart counts
/// as the same, like FAT disks) and size, and optionally by content.
package nonisolated enum FolderCompare {
    package struct Item: Sendable, Equatable {
        package let isDirectory: Bool
        package let isLink: Bool
        package let size: Int64
        package let modified: Date
        /// Its spelling on its own side (it can differ in case from the other side's on a case-insensitive disk).
        package var path: String = ""
    }

    package enum Kind: Sendable, Equatable {
        case onlyLeft, onlyRight
        case leftNewer, rightNewer
        /// Same date, different size or content: which one is right can't be told.
        case changed
        /// A file on one side, a folder (or a link) on the other.
        case kindsDiffer
        /// Couldn't be read (permissions), or names only case tells apart on one side while the other can't: left alone.
        case unknown

        package var title: String {
            switch self {
            case .onlyLeft: String(localized: "Only on the left", comment: "Compare Folders: how an item differs")
            case .onlyRight: String(localized: "Only on the right", comment: "Compare Folders: how an item differs")
            case .leftNewer: String(localized: "Newer on the left", comment: "Compare Folders: how an item differs")
            case .rightNewer: String(localized: "Newer on the right", comment: "Compare Folders: how an item differs")
            case .changed: String(localized: "Different, same date", comment: "Compare Folders: how an item differs")
            case .kindsDiffer: String(localized: "File vs. folder", comment: "Compare Folders: a file on one side, a folder on the other")
            case .unknown: String(localized: "Can’t be compared", comment: "Compare Folders: how an item differs")
            }
        }

        package var symbol: String {
            switch self {
            case .onlyLeft: "arrow.left.square"
            case .onlyRight: "arrow.right.square"
            case .leftNewer: "clock.arrow.circlepath"
            case .rightNewer: "clock.arrow.circlepath"
            case .changed: "exclamationmark.triangle"
            case .kindsDiffer: "questionmark.square"
            case .unknown: "lock.square"
            }
        }
    }

    package struct Difference: Sendable, Identifiable, Equatable {
        /// The relative path ("Photos/2024/a.jpg"), as spelled on the left when it's there.
        package let id: String
        package let kind: Kind
        package let left: Item?
        package let right: Item?
        /// Why it can't be compared (`.unknown`).
        package var note: String?

        /// Where it is (or goes) on each side: an item that exists keeps its own spelling.
        package var leftPath: String { left?.path ?? right?.path ?? id }
        package var rightPath: String { right?.path ?? left?.path ?? id }
    }

    package struct Result: Sendable {
        package var differences: [Difference] = []
        package var identical = 0
        package var scanned = 0
        /// Stopped at `itemLimit` on a side: the list is incomplete.
        package var truncated = false
        package var cancelled = false
        /// A side couldn't be read at all.
        package var failure: String?

        /// Whether a sync can trust what's listed: everything was read (folders that couldn't be are left alone).
        package var isComplete: Bool { !truncated && !cancelled && failure == nil }
    }

    /// More than this on one side, and the comparison stops (and says so).
    package static let itemLimit = 300_000
    /// Modification dates this close count as the same.
    package static let dateTolerance: TimeInterval = 2

    /// Stops a comparison in progress.
    package final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        package init() {}

        package var isCancelled: Bool { lock.withLock { stopped } }
        package func cancel() { lock.withLock { stopped = true } }
    }

    @concurrent
    package static func compare(_ left: URL, _ right: URL, contents: Bool, includeHidden: Bool, control: Control,
                        progress: @escaping @Sendable (Int) -> Void) async -> Result {
        var result = Result()
        for root in [left, right] where !FileManager.default.isReadableFile(atPath: root.path) {
            result.failure = String(localized: "“\(root.lastPathComponent)” can’t be read.")
            return result
        }
        var seen = 0
        let report: () -> Void = {
            seen += 1
            if seen % 2000 == 0 { progress(seen) }
        }
        // Names are matched the way the disks do: on a case-insensitive disk (the usual) "Report.txt" and
        // "report.txt" are the same item.
        let ignoringCase = !caseSensitive(left) || !caseSensitive(right)
        let leftScan = scan(left, includeHidden: includeHidden, ignoringCase: ignoringCase, control: control, counted: report)
        let rightScan = scan(right, includeHidden: includeHidden, ignoringCase: ignoringCase, control: control, counted: report)
        let fat = isFATLike(left) || isFATLike(right)
        result.scanned = leftScan.items.count + rightScan.items.count
        result.truncated = leftScan.truncated || rightScan.truncated
        guard !control.isCancelled else {
            result.cancelled = true
            return result
        }
        let leftItems = leftScan.items, rightItems = rightScan.items
        let unknown = leftScan.unknown.merging(rightScan.unknown) { first, _ in first }
        let keys = Set(leftItems.keys).union(rightItems.keys).union(unknown.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        /// Whether `key`'s folder is a folder on both sides (otherwise a row above already covers it).
        func parentShared(_ key: String) -> Bool {
            let parent = (key as NSString).deletingLastPathComponent
            return parent.isEmpty || (leftItems[parent]?.isDirectory == true && rightItems[parent]?.isDirectory == true
                && leftItems[parent]?.isLink == false && rightItems[parent]?.isLink == false && unknown[parent] == nil)
        }
        /// Whether `key` is inside something that couldn't be read (on either side).
        func insideUnknown(_ key: String) -> Bool {
            var parent = (key as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if unknown[parent] != nil { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
        for key in keys {
            if control.isCancelled {
                result.cancelled = true
                break
            }
            guard !insideUnknown(key) else { continue }
            if let reason = unknown[key] {
                let l = leftItems[key], r = rightItems[key]
                result.differences.append(Difference(id: l?.path ?? r?.path ?? key, kind: .unknown, left: l, right: r, note: reason))
                continue
            }
            guard parentShared(key) else { continue }
            let l = leftItems[key], r = rightItems[key]
            guard let l, let r else {
                guard let item = l ?? r else { continue }
                result.differences.append(Difference(id: item.path, kind: l == nil ? .onlyRight : .onlyLeft, left: l, right: r))
                continue
            }
            if l.isDirectory != r.isDirectory || l.isLink != r.isLink {
                result.differences.append(Difference(id: l.path, kind: .kindsDiffer, left: l, right: r))
                continue
            }
            if l.isDirectory && !l.isLink { continue }
            let gap = l.modified.timeIntervalSince(r.modified)
            // FAT and exFAT keep local time: across a daylight-saving change everything looks an hour apart.
            let sameDate = abs(gap) <= dateTolerance || fat && abs(abs(gap) - 3600) <= dateTolerance
            let newer: Kind = gap > 0 ? .leftNewer : .rightNewer
            var same: Bool
            if l.isLink {
                same = (try? FileManager.default.destinationOfSymbolicLink(atPath: left.appending(path: l.path).path))
                    == (try? FileManager.default.destinationOfSymbolicLink(atPath: right.appending(path: r.path).path))
            } else if l.size != r.size {
                same = false
            } else if contents {
                same = sameBytes(left.appending(path: l.path), right.appending(path: r.path), control: control)
            } else {
                same = sameDate
            }
            if same {
                result.identical += 1
            } else {
                result.differences.append(Difference(id: l.path, kind: sameDate ? .changed : newer, left: l, right: r))
            }
        }
        return result
    }

    /// Whether the disk holding `url` tells "a" from "A" in names.
    private static func caseSensitive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    /// FAT or exFAT (modification times in local time, two-second steps).
    private static func isFATLike(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "msdos" || type == "exfat"
    }

    private struct Scan {
        /// By key: the relative path, lowercased when names are matched ignoring case.
        var items: [String: Item] = [:]
        /// Folders that couldn't be read, and names that clash once case is ignored: why.
        var unknown: [String: String] = [:]
        var truncated = false
    }

    /// Every item under `root` by relative path (links aren't followed; .DS_Store, sockets, pipes and devices are left
    /// out, and hidden items unless asked for).
    private static func scan(_ root: URL, includeHidden: Bool, ignoringCase: Bool, control: Control, counted: () -> Void) -> Scan {
        var scan = Scan()
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return scan }
        let base = root.path
        while let relative = walker.nextObject() as? String {
            if control.isCancelled { break }
            let name = (relative as NSString).lastPathComponent
            if name == ".DS_Store" { continue }
            var info = stat()
            guard lstat(base + "/" + relative, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if !includeHidden, name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 {
                if type == S_IFDIR { walker.skipDescendants() }
                continue
            }
            guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else { continue }
            let key = ignoringCase ? relative.lowercased() : relative
            if let other = scan.items[key], other.path != relative {
                scan.unknown[key] = String(localized: "“\(other.path)” and “\(relative)” differ only in case; the other side can’t tell them apart")
                if type == S_IFDIR { walker.skipDescendants() }
                continue
            }
            // A folder that can't be read would look empty: what's inside is unknown, not missing.
            if type == S_IFDIR, access(base + "/" + relative, R_OK | X_OK) != 0 {
                scan.unknown[key] = String(localized: "“\(relative)” can’t be read", comment: "Compare Folders: why a folder can’t be compared")
                walker.skipDescendants()
            }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            scan.items[key] = Item(isDirectory: type == S_IFDIR, isLink: type == S_IFLNK, size: Int64(info.st_size), modified: modified,
                                   path: relative)
            counted()
            if scan.items.count >= itemLimit {
                scan.truncated = true
                break
            }
        }
        return scan
    }

    /// Whether two files hold the same bytes, read side by side (stops at the first difference).
    package static func sameBytes(_ a: URL, _ b: URL, control: Control) -> Bool {
        func openRegular(_ url: URL) -> (FileHandle, Int64)? {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                close(fd)
                return nil
            }
            let flags = fcntl(fd, F_GETFL)
            if flags != -1 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
            return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), info.st_size)
        }
        func readChunk(_ handle: FileHandle, count: Int) throws -> Data {
            var buffer = Data()
            while buffer.count < count {
                guard let piece = try handle.read(upToCount: count - buffer.count), !piece.isEmpty else { break }
                buffer.append(piece)
            }
            return buffer
        }
        guard let (first, sizeA) = openRegular(a), let (second, sizeB) = openRegular(b) else { return false }
        defer {
            try? first.close()
            try? second.close()
        }
        guard sizeA == sizeB else { return false }
        while !control.isCancelled {
            do {
                let x = try readChunk(first, count: 1 << 20)
                let y = try readChunk(second, count: 1 << 20)
                if x != y { return false }
                if x.isEmpty { return true }
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: - Syncing

    package enum Direction: Int, Sendable, CaseIterable {
        case bothWays, leftToRight, rightToLeft

        package var title: String {
            switch self {
            case .bothWays: String(localized: "Both Ways", comment: "Compare Folders: sync direction")
            case .leftToRight: String(localized: "Left to Right", comment: "Compare Folders: sync direction")
            case .rightToLeft: String(localized: "Right to Left", comment: "Compare Folders: sync direction")
            }
        }
    }

    package enum Action: Int, Sendable, CaseIterable {
        case copyRight, copyLeft, trashLeft, trashRight, skip

        package var title: String {
            switch self {
            case .copyRight: String(localized: "Copy →", comment: "Compare Folders: copy the item to the right side")
            case .copyLeft: String(localized: "← Copy", comment: "Compare Folders: copy the item to the left side")
            case .trashLeft: String(localized: "Trash on the left", comment: "Compare Folders: move the left item to the Trash")
            case .trashRight: String(localized: "Trash on the right", comment: "Compare Folders: move the right item to the Trash")
            case .skip: String(localized: "Skip", comment: "Compare Folders: leave the item as it is")
            }
        }
    }

    /// What can be done with a difference.
    package static func actions(for kind: Kind) -> [Action] {
        switch kind {
        case .onlyLeft: [.copyRight, .trashLeft, .skip]
        case .onlyRight: [.copyLeft, .trashRight, .skip]
        case .leftNewer, .rightNewer, .changed, .kindsDiffer: [.copyRight, .copyLeft, .skip]
        case .unknown: [.skip]
        }
    }

    /// What a sync does by default. Both ways: newer wins, what's only on one side is copied, and items that differ
    /// with the same date (or a file against a folder) are left for you. One way: the source wins, and with `mirror`
    /// what's only on the other side goes to the Trash.
    package static func defaultAction(for kind: Kind, direction: Direction, mirror: Bool) -> Action {
        switch (direction, kind) {
        case (_, .unknown): .skip
        case (.bothWays, .onlyLeft): .copyRight
        case (.bothWays, .onlyRight): .copyLeft
        case (.bothWays, .leftNewer): .copyRight
        case (.bothWays, .rightNewer): .copyLeft
        case (.bothWays, .changed), (.bothWays, .kindsDiffer): .skip
        case (.leftToRight, .onlyRight): mirror ? .trashRight : .skip
        case (.leftToRight, _): .copyRight
        case (.rightToLeft, .onlyLeft): mirror ? .trashLeft : .skip
        case (.rightToLeft, _): .copyLeft
        }
    }

    /// What a sync does, as paths: the copies each way, and what it moves to the Trash on each side.
    package struct SyncPlan: Sendable, Equatable {
        package var toRight: [TransferMove] = []
        package var toLeft: [TransferMove] = []
        package var trashLeft: [URL] = []
        package var trashRight: [URL] = []
        /// Copies that put a file where a folder is, or a folder where a file is.
        package var replacesOtherKind = 0

        package var isEmpty: Bool { toRight.isEmpty && toLeft.isEmpty && trashLeft.isEmpty && trashRight.isEmpty }
    }

    /// The sync of `left` and `right` that `actions` ask for (by difference ID; none is skip). Each side's items are
    /// spelled as on that side, and an action a difference doesn't allow (`actions(for:)`) is skipped.
    package static func syncPlan(_ differences: [Difference], actions: [String: Action], left: URL, right: URL) -> SyncPlan {
        var plan = SyncPlan()
        for difference in differences {
            let action = actions[difference.id] ?? .skip
            guard Self.actions(for: difference.kind).contains(action) else { continue }
            let l = left.appending(path: difference.leftPath), r = right.appending(path: difference.rightPath)
            if difference.kind == .kindsDiffer, action == .copyRight || action == .copyLeft { plan.replacesOtherKind += 1 }
            switch action {
            case .copyRight: plan.toRight.append(TransferMove(from: l, to: r))
            case .copyLeft: plan.toLeft.append(TransferMove(from: r, to: l))
            case .trashLeft: plan.trashLeft.append(l)
            case .trashRight: plan.trashRight.append(r)
            case .skip: break
            }
        }
        return plan
    }
}

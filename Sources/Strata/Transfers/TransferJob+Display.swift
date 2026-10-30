import Foundation

/// The words a job shows in the Transfers list and in tooltips.
extension TransferJob {
    /// "Copying 1,204 items to Downloads", "Moved “Report.pdf” to Archive".
    var title: String {
        let done = state == .finished
        let to = destinationName
        guard sources.count == 1 else {
            let n = sources.count
            if actionName == "Put Back" {
                return done ? String(localized: "Put back \(n) items", comment: "plural")
                    : String(localized: "Putting back \(n) items", comment: "plural")
            }
            return switch (mode, done) {
            case (.copy, false): String(localized: "Copying \(n) items to \(to)", comment: "plural")
            case (.copy, true): String(localized: "Copied \(n) items to \(to)", comment: "plural")
            case (.move, false): String(localized: "Moving \(n) items to \(to)", comment: "plural")
            case (.move, true): String(localized: "Moved \(n) items to \(to)", comment: "plural")
            }
        }
        let name = sources[0].lastPathComponent
        if actionName == "Put Back" {
            return done ? String(localized: "Put back “\(name)”", comment: "Transfers list: an item taken out of the Trash")
                : String(localized: "Putting back “\(name)”", comment: "Transfers list: an item being taken out of the Trash")
        }
        return switch (mode, done) {
        case (.copy, false): String(localized: "Copying “\(name)” to \(to)", comment: "Transfers list: item, then the destination folder")
        case (.copy, true): String(localized: "Copied “\(name)” to \(to)", comment: "Transfers list: item, then the destination folder")
        case (.move, false): String(localized: "Moving “\(name)” to \(to)", comment: "Transfers list: item, then the destination folder")
        case (.move, true): String(localized: "Moved “\(name)” to \(to)", comment: "Transfers list: item, then the destination folder")
        }
    }

    /// "2.1 GB of 5.4 GB · 84 MB/s · about 40 s left", "Paused", "Done · 3 failed"…
    var statusText: String {
        if isAwaitingDecision { return String(localized: "Waiting for your decision") }
        switch state {
        case .queued:
            return isWaitingForDisk ? String(localized: "Waiting for another transfer to this disk")
                : String(localized: "Waiting…", comment: "Transfers list: a job waiting its turn")
        case .scanning:
            return totalFiles > 0 ? String(localized: "Preparing · \(totalFiles) items", comment: "plural")
                : String(localized: "Preparing…", comment: "Transfers list: a job reading what it will do")
        case .running:
            var parts = [amountText]
            if let throughput, throughput >= 1, totalBytes > 0 { parts.append(TransferFormat.rate(throughput)) }
            if let estimatedTimeRemaining { parts.append(TransferFormat.remaining(estimatedTimeRemaining)) }
            return parts.joined(separator: " · ")
        case .paused:
            return String(localized: "Paused · \(amountText)", comment: "Transfers list: a paused job, then how much is done")
        case .finished:
            var parts = [String(localized: "Done", comment: "Transfers list: job status")]
            if !failures.isEmpty { parts.append(TransferFormat.failed(failures.count)) }
            if skippedCount > 0 { parts.append(String(localized: "\(skippedCount) skipped", comment: "plural")) }
            if failures.isEmpty, options.verify {
                parts.append(String(localized: "verified", comment: "Transfers list: after “Done ·”, every copy was checked"))
            }
            return parts.joined(separator: " · ")
        case .failed:
            if let errorMessage { return errorMessage }
            if failures.count == 1 { return failures[0].message }
            return String(localized: "Failed · \(failures.count) errors", comment: "plural")
        case .cancelled:
            return completedItems > 0
                ? String(localized: "Stopped · \(completedItems.formatted()) of \(sources.count.formatted()) done",
                         comment: "Transfers list: a cancelled job, with how many of its items were done")
                : String(localized: "Stopped", comment: "Transfers list: job status (cancelled)")
        }
    }

    /// "2.1 GB of 5.4 GB", or item counts when the job is mostly tiny files.
    private var amountText: String {
        if totalBytes < 1_000_000, totalFiles > 1 {
            let done = min(completedFiles, totalFiles).formatted()
            return isVerifying ? String(localized: "Verifying · \(done) of \(totalFiles) items", comment: "plural")
                : String(localized: "\(done) of \(totalFiles) items", comment: "plural")
        }
        let done = Format.bytes(min(isVerifying ? verifiedBytes : completedBytes, totalBytes)), total = Format.bytes(totalBytes)
        return isVerifying ? String(localized: "Verifying · \(done) of \(total)", comment: "Transfers list: sizes, like 2.1 GB of 5.4 GB")
            : String(localized: "\(done) of \(total)", comment: "Transfers list: sizes, like 2.1 GB of 5.4 GB")
    }

    /// Up to eight failures, one per line, for a tooltip.
    var failureSummary: String? {
        if let errorMessage { return errorMessage }
        guard !failures.isEmpty else { return nil }
        var lines = failures.prefix(8).map { "\($0.displayName) — \($0.message)" }
        if failures.count > 8 { lines.append(String(localized: "and \(failures.count - 8) more", comment: "plural")) }
        return lines.joined(separator: "\n")
    }

    var symbolName: String {
        mode == .copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard"
    }
}

enum TransferFormat {
    static func rate(_ bytesPerSecond: Double) -> String {
        let clamped = bytesPerSecond.isFinite && bytesPerSecond > 0 ? min(bytesPerSecond, Double(Int64.max / 2)) : 0
        return String(localized: "\(Format.bytes(Int64(clamped)))/s", comment: "Transfer speed, like 84 MB/s")
    }

    /// "a few seconds left", "about 40 s left", "about 3 min left", "about 1 h 20 min left".
    static func remaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 5 else { return String(localized: "a few seconds left") }
        if seconds < 55 { return String(localized: "about \(Int((seconds / 5).rounded()) * 5) s left", comment: "Time left, in seconds") }
        let minutes = max(1, Int(min(seconds / 60, Double(Int.max / 2)).rounded()))
        if minutes < 60 { return String(localized: "about \(minutes) min left", comment: "Time left, in minutes") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? String(localized: "about \(hours) h left", comment: "Time left, in hours")
            : String(localized: "about \(hours) h \(rest) min left", comment: "Time left, in hours and minutes")
    }

    /// "3 failed", in a finished job's status (the Transfers list shows it in red).
    static func failed(_ count: Int) -> String {
        String(localized: "\(count) failed", comment: "plural")
    }
}

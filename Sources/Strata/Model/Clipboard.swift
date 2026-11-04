import AppKit

extension Notification.Name {
    package static let clipboardChanged = Notification.Name("StrataClipboardChanged")
}

/// Finder-compatible file clipboard, plus Cut: the next paste moves the chosen items.
@MainActor package final class Clipboard {
    package struct Contents: Equatable, Sendable {
        package let changeCount: Int
        package let count: Int
        package let urls: [URL]
        package let isCut: Bool
    }

    private static let inspectionLimit = 200
    private static let pollingInterval: TimeInterval = 0.5
    package static let shared = Clipboard(pasteboard: .general, notifications: .default)

    package let pasteboard: NSPasteboard
    package let notifications: NotificationCenter
    private var cut: (urls: Set<URL>, changeCount: Int)?
    package private(set) var contents: Contents?
    private var monitors: Set<UUID> = []
    private var timer: Timer?

    package init(pasteboard: NSPasteboard, notifications: NotificationCenter) {
        self.pasteboard = pasteboard
        self.notifications = notifications
    }

    isolated deinit { timer?.invalidate() }

    package func write(_ urls: [URL], cut isCut: Bool) {
        pasteboard.clearContents()
        let written = pasteboard.writeObjects(urls as [NSURL])
        cut = written && isCut ? (Set(urls), pasteboard.changeCount) : nil
        contents = !written || urls.isEmpty ? nil : Contents(changeCount: pasteboard.changeCount, count: urls.count,
            urls: Array(urls.prefix(Self.inspectionLimit)), isCut: isCut)
        changed()
    }

    package func read() -> (urls: [URL], isCut: Bool) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, cut?.changeCount == pasteboard.changeCount)
    }

    package func isCut(_ url: URL) -> Bool {
        guard let cut, cut.changeCount == pasteboard.changeCount else { return false }
        return cut.urls.contains(url)
    }

    package func clearCut() {
        cut = nil
        if let contents, contents.changeCount == pasteboard.changeCount {
            self.contents = Contents(changeCount: contents.changeCount, count: contents.count, urls: contents.urls, isCut: false)
        } else { contents = nil }
        changed()
    }

    package var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Puts `text` there instead (a branch name, a command).
    package func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        cut = nil
        contents = nil
        changed()
    }

    package func clear(ifUnchanged changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { refresh(); return false }
        pasteboard.clearContents()
        cut = nil
        contents = nil
        changed()
        return true
    }

    package func refresh() {
        // Track our file writes. Reading another app's clipboard can request slow or sensitive promised data.
        guard let contents, contents.changeCount != pasteboard.changeCount else { return }
        self.contents = nil
        cut = nil
        changed()
    }

    package func monitor() -> UUID {
        let id = UUID()
        monitors.insert(id)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer?.tolerance = Self.pollingInterval / 2
        }
        return id
    }

    package func stopMonitoring(_ id: UUID) {
        monitors.remove(id)
        if monitors.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func changed() { notifications.post(name: .clipboardChanged, object: self) }
}

import AppKit

extension Notification.Name {
    package static let clipboardChanged = Notification.Name("StrataClipboardChanged")
}

/// Finder-compatible file clipboard, plus Cut: the next paste moves the chosen items.
package final class Clipboard {
    package static let shared = Clipboard(pasteboard: .general, notifications: .default)

    package let pasteboard: NSPasteboard
    package let notifications: NotificationCenter
    private var cut: (urls: Set<URL>, changeCount: Int)?

    package init(pasteboard: NSPasteboard, notifications: NotificationCenter) {
        self.pasteboard = pasteboard
        self.notifications = notifications
    }

    package func write(_ urls: [URL], cut isCut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cut = isCut ? (Set(urls), pasteboard.changeCount) : nil
        notifications.post(name: .clipboardChanged, object: nil)
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
        notifications.post(name: .clipboardChanged, object: nil)
    }

    package var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Puts `text` there instead (a branch name, a command).
    package func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        cut = nil
        notifications.post(name: .clipboardChanged, object: nil)
    }
}

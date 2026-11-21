import AppKit

nonisolated enum FileApplications {
    static func defaultApplication(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    @MainActor static func open(_ urls: [URL], in application: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}

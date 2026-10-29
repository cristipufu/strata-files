import AppKit

/// Check for Updates… on selected apps.
extension BrowserViewController {
    /// The apps in the selection: with everything in Applications selected, the Utilities folder doesn't take the command
    /// away. Not apps in a Trash, or inside an archive opened as a folder.
    var selectedApps: [URL] {
        guard !isShowingTrash, !isInsideArchive else { return [] }
        return selectedEntries.filter { $0.isPackage && $0.url.pathExtension.lowercased() == "app" && !Trash.isInTrash($0.url) }.map(\.url)
    }

    /// "Check for Updates…", or "Check 12 Apps for Updates…" when other things are selected too.
    var appUpdatesTitle: String {
        let apps = selectedApps.count
        return apps == selectedEntries.count ? String(localized: "Check for Updates…")
            : String(localized: "Check \(apps) Apps for Updates…", comment: "plural; the selection also holds things that aren't apps")
    }

    @objc func checkAppsForUpdates(_ sender: Any?) {
        let apps = selectedApps
        guard !apps.isEmpty, let window = view.window, window.attachedSheet == nil else { return Sounds.beep() }
        // This Strata alone: its own updater shows what's new and installs it.
        if apps.count == 1, AppUpdatesController.isThisCopyOfStrata(apps[0]), Updates.shared.canCheck {
            return Updates.shared.checkNow(sender)
        }
        presentAsSheet(AppUpdatesController(urls: apps))
    }
}

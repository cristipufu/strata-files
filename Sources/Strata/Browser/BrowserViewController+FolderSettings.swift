import AppKit

extension BrowserViewController {
    var canRememberFolderPresentation: Bool {
        isLoaded && !isShowingResults && loadError == nil && directory.map(canSaveFolderView(at:)) == true
    }

    private func canSaveFolderView(at folder: URL) -> Bool {
        folder.isFileURL && !services.copies.contains(folder) && !ArchiveCache.contains(folder)
    }

    var folderPresentation: FolderPresentation {
        FolderPresentation(mode: mode, sort: ordering.choice ?? services.folderViews.defaults.sort, iconSize: iconSize)
    }

    func rememberFolderPresentation() {
        guard !isShowingResults, loadError == nil, let directory else { return }
        if !isLoaded { pendingFolderPresentation = folderPresentation }
        else if canRememberFolderPresentation { services.folderViews.save(folderPresentation, for: directory) }
    }

    func restoreFolderPresentation(at folder: URL, showing: Bool) {
        let canRemember = canSaveFolderView(at: folder)
        var saved = canRemember ? services.folderViews.presentation(for: folder) : services.folderViews.defaults
        if let initialMode { saved.mode = initialMode }
        if let initialSort { saved.sort = initialSort }
        setIconSize(saved.iconSize, remember: false)
        if showing {
            setMode(saved.mode, remember: false)
            if ordering.choice != saved.sort { applySort(saved.sort.key, ascending: saved.sort.ascending, remember: false) }
        } else {
            setStoredMode(saved.mode)
            ordering.choose(saved.sort, remember: false)
            syncSortDescriptor()
            installActiveView()
        }
        folderOptions?.refresh()
    }

    @objc func folderViewSettingsChanged(_ notification: Notification) {
        guard let directory else { return }
        if let key = notification.userInfo?["folderKey"] as? String, key != services.folderViews.key(for: directory) { return }
        if isShowingResults { folderSettingsChangedInResults = true; return }
        guard canRememberFolderPresentation else { return }
        initialMode = nil; initialSort = nil
        restoreFolderPresentation(at: directory, showing: true)
    }

    func setIconSize(_ size: Double, remember: Bool = true) {
        let range = FolderPresentation.iconSizeRange
        let size = size.isFinite ? min(max(size, range.lowerBound), range.upperBound) : services.folderViews.defaults.iconSize
        setStoredIconSize(size)
        gridController?.setIconSize(CGFloat(size), animated: false)
        if remember {
            if directory != nil { rememberFolderPresentation() }
            else if !isShowingResults { preferences.gridIconSize = size }
        }
    }
}

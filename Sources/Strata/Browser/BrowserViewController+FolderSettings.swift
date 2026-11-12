import AppKit

extension BrowserViewController {
    var canCustomizeFolderPresentation: Bool {
        !isShowingResults && loadError == nil && directory.map(canSaveFolderView(at:)) == true
    }

    var canRememberFolderPresentation: Bool {
        isLoaded && canCustomizeFolderPresentation
    }

    var hasCustomFolderPresentation: Bool {
        pendingFolderPresentation != nil || directory.flatMap(services.folderViews.stored(for:)) != nil
    }

    private func canSaveFolderView(at folder: URL) -> Bool {
        folder.isFileURL && !services.copies.contains(folder) && !ArchiveCache.contains(folder)
    }

    var iconSizeForViewOptions: Double {
        if isShowingResults { return iconSize }
        if let pendingFolderPresentation { return pendingFolderPresentation.iconSize }
        guard let directory, canSaveFolderView(at: directory) else { return preferences.gridIconSize }
        return services.folderViews.presentation(for: directory).iconSize
    }

    var folderPresentation: FolderPresentation {
        FolderPresentation(mode: mode, sort: ordering.choice ?? services.folderViews.defaults.sort, iconSize: iconSize)
    }

    func rememberFolderPresentation() {
        guard canCustomizeFolderPresentation, let directory else { return }
        if !isLoaded { pendingFolderPresentation = folderPresentation }
        else if canRememberFolderPresentation { services.folderViews.save(folderPresentation, for: directory) }
    }

    func customizeFolderPresentation(_ update: (inout FolderPresentation) -> Void) {
        guard canCustomizeFolderPresentation else { return }
        var value = folderPresentation
        update(&value)
        if value.iconSize != iconSize { setIconSize(value.iconSize, remember: false) }
        if value.mode != mode { setMode(value.mode, remember: false) }
        if ordering.choice != value.sort { applySort(value.sort.key, ascending: value.sort.ascending, remember: false) }
        rememberFolderPresentation()
        folderOptions?.refresh()
    }

    /// Forgets the current folder's saved view without creating one where there is none. A folder still being read
    /// takes the current defaults or reset view now: the change notification restores only folders already shown,
    /// and the read landing restores nothing.
    func resetFolderPresentation() {
        guard canCustomizeFolderPresentation, let directory else { return }
        if hasCustomFolderPresentation {
            pendingFolderPresentation = nil
            services.folderViews.reset(directory)
        }
        if !isLoaded { restoreFolderPresentation(at: directory, showing: false) }
        folderOptions?.refresh()
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
        if remember, !isShowingResults {
            if hasCustomFolderPresentation { rememberFolderPresentation() }
            else { preferences.gridIconSize = size }
            folderOptions?.refresh()
        }
    }
}

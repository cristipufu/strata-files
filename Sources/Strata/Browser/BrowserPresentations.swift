import AppKit

/// Owns the browser's cached native presentations and their attachment. Creation stays lazy; a hidden view keeps
/// its scroll position and selection but gets fresh content and theme colors when shown again.
final class BrowserPresentations {
    private(set) var gridController: GridViewController?
    private(set) var columnController: ColumnBrowserViewController?
    private(set) var galleryController: GalleryViewController?
    private(set) var treemapController: TreemapViewController?

    var cached: [FileCollectionController] {
        [gridController, columnController, galleryController, treemapController].compactMap { $0 }
    }

    func controller(for mode: BrowserViewMode, in browser: BrowserViewController) -> FileCollectionController? {
        switch mode {
        case .list: nil
        case .grid: grid(in: browser)
        case .columns: columns(in: browser)
        case .gallery: gallery(in: browser)
        case .treemap: treemap(in: browser)
        }
    }

    func install(_ mode: BrowserViewMode, in browser: BrowserViewController) {
        let active = controller(for: mode, in: browser)
        if active != nil { browser.inlineRename.cancel() }
        for controller in cached where controller !== active && controller.isViewLoaded {
            controller.cancelRename()
            controller.view.removeFromSuperview()
        }
        guard let active else {
            browser.outlineScrollView.isHidden = false
            return
        }
        if active.parent == nil { browser.addChild(active) }
        if active.view.superview == nil {
            active.view.translatesAutoresizingMaskIntoConstraints = false
            browser.view.addSubview(active.view, positioned: .above, relativeTo: browser.outlineScrollView)
            let inset = active.insetsContentToSafeArea
            NSLayoutConstraint.activate([
                active.view.leadingAnchor.constraint(equalTo: browser.view.leadingAnchor),
                active.view.trailingAnchor.constraint(equalTo: browser.view.trailingAnchor),
                active.view.topAnchor.constraint(equalTo: inset ? browser.view.safeAreaLayoutGuide.topAnchor : browser.view.topAnchor),
                active.view.bottomAnchor.constraint(equalTo: inset ? browser.view.safeAreaLayoutGuide.bottomAnchor : browser.view.bottomAnchor),
            ])
            ThemeStyle.refresh(active.view)
        }
        browser.outlineScrollView.isHidden = true
    }

    func grid(in browser: BrowserViewController) -> GridViewController {
        if let gridController { return gridController }
        let controller = GridViewController(preferences: browser.preferences, thumbnails: browser.services.thumbnails,
                                            itemInfo: browser.services.itemInfo, copies: browser.services.copies,
                                            clipboard: browser.services.clipboard, statuses: browser.services.statuses)
        controller.fileDelegate = browser
        controller.setIconSize(CGFloat(browser.preferences.gridIconSize), animated: false)
        controller.showsItemInfo = browser.preferences.iconViewOptions.showsInfo
        controller.folderSizeText = { [weak browser] entry in
            guard let browser, browser.preferences.iconViewOptions.folderInfo == .size else { return nil }
            return browser.iconFolderSizeText(entry)
        }
        gridController = controller
        return controller
    }

    func columns(in browser: BrowserViewController) -> ColumnBrowserViewController {
        if let columnController { return columnController }
        let controller = ColumnBrowserViewController(directoryReader: browser.services.directories, preferences: browser.preferences,
                                                     thumbnails: browser.services.thumbnails, itemInfo: browser.services.itemInfo,
                                                     copies: browser.services.copies, clipboard: browser.services.clipboard,
                                                     statuses: browser.services.statuses, names: browser.services.folderNames)
        controller.applicationFolders = browser.applicationFolders
        controller.fileDelegate = browser
        controller.onLocationChange = { [weak browser] url in
            guard let browser else { return }
            browser.delegate?.browser(browser, columnLocationChanged: url)
        }
        columnController = controller
        return controller
    }

    func gallery(in browser: BrowserViewController) -> GalleryViewController {
        if let galleryController { return galleryController }
        let controller = GalleryViewController(thumbnails: browser.services.thumbnails, copies: browser.services.copies,
                                               clipboard: browser.services.clipboard, statuses: browser.services.statuses)
        controller.fileDelegate = browser
        galleryController = controller
        return controller
    }

    func treemap(in browser: BrowserViewController) -> TreemapViewController {
        if let treemapController { return treemapController }
        let controller = TreemapViewController(copies: browser.services.copies)
        controller.fileDelegate = browser
        controller.onDrill = { [weak browser] url in
            guard let browser else { return }
            browser.delegate?.browser(browser, navigateTo: url)
        }
        treemapController = controller
        return controller
    }
}

import AppKit
import Quartz

extension BrowserViewController {
    @objc func toggleQuickLook(_ sender: Any?) {
        guard !inlineRename.isEditing else { return }
        if services.previews.isOpen {
            services.previews.close()
            return
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        if selectedEntries.count == 1, let entry = selectedEntries.first {
            services.previews.show(entry, from: self)
        } else if let panel = QLPreviewPanel.shared() {
            openQuickLook { [weak self] in
                guard let self else { return }
                _ = services.windows.preview(panel, focusView)
            }
        }
    }

    func openQuickLook(showPanel: @escaping () -> Void = { QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil) }) {
        let urls = Self.quickLookItems(selectedEntries)
        let selectedKeys = Set(selectedURLs.map(Self.key))
        guard !selectedKeys.isEmpty else { return }
        let hadWindow = viewIfLoaded?.window != nil
        // A container's file being fetched: show it once it's here.
        afterFetching(urls) { [weak self] in
            guard let self, (!hadWindow || viewIfLoaded?.window?.isVisible == true),
                  !Set(selectedURLs.map(Self.key)).isDisjoint(with: selectedKeys) else { return }
            showPanel()
        }
    }

    // Quick Look calls these on the main thread; the SDK just doesn't annotate them.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

// MARK: - The panel's items

extension BrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs
        return urls.indices.contains(index) ? (urls[index] as NSURL) : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, !inlineRename.isEditing, view.window?.attachedSheet == nil,
              !(view.window?.firstResponder is NSText) else { return false }
        focusView.keyDown(with: event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = (item as? NSURL) as URL? else { return .zero }
        return iconScreenRect(for: url) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = (item as? NSURL) as URL? else { return nil }
        guard let entry = selectedEntries.first(where: { Self.key($0.url) == Self.key(url) }) ?? node(for: url)?.entry else { return nil }
        // The thumbnail the row shows, so the zoom starts from what's on screen.
        let scale = view.window?.backingScaleFactor ?? 2
        if preferences.showIconPreviews, services.thumbnails.canThumbnail(entry),
           let thumbnail = services.thumbnails.cached(entry, size: NameCellView.iconSide, scale: scale) { return thumbnail.image }
        return services.thumbnails.icon(for: entry)
    }
}

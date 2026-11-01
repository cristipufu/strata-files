import AppKit

extension BrowserViewController {
    struct InspectorTarget {
        private weak var browser: BrowserViewController?
        private let revision: Int
        private let mode: BrowserViewMode
        private let urls: [URL]

        init(browser: BrowserViewController, urls: [URL]) {
            self.browser = browser
            revision = browser.navigationRevision
            mode = browser.effectiveMode
            self.urls = urls
        }

        func matches(_ browser: BrowserViewController) -> Bool {
            self.browser === browser && revision == browser.navigationRevision && mode == browser.effectiveMode
                && urls == browser.selectedURLs
        }
    }

    func canGetInfo(_ represented: Any?) -> Bool {
        if let represented {
            guard let target = represented as? InspectorTarget, target.matches(self) else { return false }
        }
        return PaneCommandAvailability.answer(for: StrataCommand.getInfo.action, represented: nil, in: self).isEnabled
    }

    @objc func getInfo(_ sender: Any?) {
        guard canGetInfo((sender as? NSMenuItem)?.representedObject) else { return }
        delegate?.browserShowInspector(self)
    }
}

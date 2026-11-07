import AppKit
@testable import Strata

@MainActor final class BrowserContentObserver: BrowserViewControllerDelegate {
    let changed: (BrowserViewController) -> Void
    var onLanding: ((BrowserViewController) -> Void)?
    init(_ changed: @escaping (BrowserViewController) -> Void) { self.changed = changed }
    func browserContentDidChange(_ browser: BrowserViewController) { changed(browser) }
    func browser(_ browser: BrowserViewController, navigateTo url: URL) {}
    func browserShowInspector(_ browser: BrowserViewController) {}
    func browserCapacityDidChange(_ browser: BrowserViewController) {}
    func browserSelectionDidChange(_ browser: BrowserViewController) {}
    func browser(_ browser: BrowserViewController, columnLocationChanged url: URL) {}
    func browser(_ browser: BrowserViewController, landedAt folder: URL, asked: URL) { onLanding?(browser) }
    func browser(_ browser: BrowserViewController, springLoadTo url: URL, drag: Int) {}
    func browser(_ browser: BrowserViewController, showArchiveCopy folder: URL) {}
    func browser(_ browser: BrowserViewController, openingArchive archive: URL?, stop: (() -> Void)?) {}
    func browser(_ browser: BrowserViewController, reveal url: URL) {}
}

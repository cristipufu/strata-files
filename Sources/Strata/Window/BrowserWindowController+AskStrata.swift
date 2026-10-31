import AppKit

extension BrowserWindowController {
    /// "Ask Strata…": plan-then-execute on the selection (or everything in the folder when nothing is selected).
    @objc func askStrata(_ sender: Any?) {
        presentAskStrata(instruction: nil)
    }

    func presentAskStrata(instruction: String?) {
        guard let window, window.attachedSheet == nil, !browser.isInsideArchive else { return }
        let urls = browser.selectedURLs.isEmpty ? browser.topLevelEntries.map(\.url) : browser.selectedURLs
        guard !urls.isEmpty else { return }
        let folder = location
        let selectAfterReload = selectionAfterOperation()
        let contentIndex = services.contentIndex
        PlanSheetController.present(on: window, urls: urls, baseFolder: folder, undoManager: window.undoManager,
                                    instruction: instruction, files: services.files) { [weak self] outcome in
            guard self != nil, let outcome, !outcome.results.isEmpty else { return }
            selectAfterReload(outcome.results)
            Task { for url in outcome.results { await contentIndex.refresh(url) } }
        }
    }

    /// Palette commands for the AI features, to append to `commandItems()`.
    func aiPaletteItems() -> [PaletteItem] {
        let subtitle = browser.selectedURLs.isEmpty ? String(localized: "Rename, move or organize everything here")
            : String(localized: "Rename, move or organize the selection")
        return paletteCommand(.askStrata, subtitle: subtitle).map { [$0] } ?? []
    }
}

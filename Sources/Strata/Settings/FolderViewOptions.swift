import AppKit
import Combine

final class FolderViewOptions: NSObject, ObservableObject {
    let settings: FolderViewSettings
    private weak var browser: BrowserViewController?
    @Published private(set) var folderName = ""
    @Published private(set) var presentation: FolderPresentation
    @Published private(set) var canEditFolder = false

    init(settings: FolderViewSettings) {
        self.settings = settings; presentation = settings.defaults
        super.init()
        settings.preferences.notifications.addObserver(self, selector: #selector(refresh), name: .folderViewSettingsChanged, object: settings.preferences)
    }

    func bind(_ browser: BrowserViewController) {
        self.browser?.folderOptions = nil
        guard browser.preferences === settings.preferences else { self.browser = nil; refresh(); return }
        self.browser = browser; browser.folderOptions = self
        refresh()
    }

    func detach(_ browser: BrowserViewController) {
        guard self.browser === browser else { return }
        unbind()
    }

    func unbind() { browser?.folderOptions = nil; browser = nil; refresh() }

    @objc func refresh() {
        let editable = browser?.canCustomizeFolderPresentation == true
        let snapshot = editable ? browser?.folderPresentation ?? settings.defaults : settings.defaults
        let name = editable ? browser?.directory?.lastPathComponent ?? "" : ""
        if canEditFolder != editable { canEditFolder = editable }
        if folderName != name { folderName = name }
        if presentation != snapshot { presentation = snapshot }
    }

    func chooseMode(_ mode: BrowserViewMode) { change { $0.mode = mode } }
    func chooseSort(_ key: SortKey) { change { $0.sort = .init(key: key, ascending: $0.sort.ascending) } }
    func chooseAscending(_ ascending: Bool) { change { $0.sort = .init(key: $0.sort.key, ascending: ascending) } }
    func chooseIconSize(_ size: Double) {
        change { $0.iconSize = size }
    }

    func reset() {
        guard let browser, browser.canRememberFolderPresentation, let folder = browser.directory else { return }
        settings.reset(folder)
    }

    func useAsDefaults() {
        guard browser?.canRememberFolderPresentation == true else { return }
        settings.useAsDefaults(presentation)
    }

    private func change(_ update: (inout FolderPresentation) -> Void) {
        guard let browser, browser.canCustomizeFolderPresentation else { return }
        browser.customizeFolderPresentation(update)
    }
}

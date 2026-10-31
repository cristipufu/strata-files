import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct MenuImagesTests {
    @Test func folderDestinationsHaveImages() throws {
        let app = NSApplication.shared
        let saved = (app.windowsMenu, app.helpMenu, app.servicesMenu)
        defer {
            app.windowsMenu = saved.0
            app.helpMenu = saved.1
            app.servicesMenu = saved.2
        }
        let menu = MainMenu.build()
        let actions = [#selector(BrowserWindowController.goHome(_:)),
                       #selector(BrowserWindowController.goDesktop(_:)),
                       #selector(BrowserWindowController.goDocuments(_:)),
                       #selector(BrowserWindowController.goDownloads(_:)),
                       #selector(BrowserWindowController.goApplications(_:)),
                       #selector(BrowserWindowController.goTrash(_:))]
        for action in actions {
            let item = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.action == action })
            #expect(item.image != nil)
            if item.responds(to: NSSelectorFromString("preferredImageVisibility")) {
                #expect((item.value(forKey: "preferredImageVisibility") as? NSNumber)?.intValue == 1)
            }
        }
    }

    @Test func requestsVisibleImagesWhenTheSystemSupportsThePreference() {
        let item = ImagePreference()
        MenuImages.preferVisible(item)
        #expect(item.preferredImageVisibility == 1)
        // macOS 26 has no preference; asking must leave its existing behavior alone.
        MenuImages.preferVisible(NSObject())
    }
}

private final class ImagePreference: NSObject {
    @objc dynamic var preferredImageVisibility = 0
}

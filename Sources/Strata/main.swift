import AppKit
@_exported import StrataAI
@_exported import StrataDev
@_exported import StrataFiles
@_exported import StrataSearch
@_exported import StrataIndex
@_exported import StrataModel
@_exported import StrataPreviews
@_exported import StrataSupport
@_exported import StrataTheme

SecureStorage.useApplicationStorage()
Prefs.useApplicationPreferences()
Sounds.useApplicationSounds()
let app = NSApplication.shared
CloudStore.shared.foldersShown = BrowserWindowController.foldersShown
let delegate = AppDelegate(browserServices: .shared)
app.delegate = delegate
app.run()

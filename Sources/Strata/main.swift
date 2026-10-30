import AppKit
@_exported import StrataIndex
@_exported import StrataModel
@_exported import StrataPreviews
@_exported import StrataSupport
@_exported import StrataTheme

SecureStorage.useApplicationStorage()
Prefs.useApplicationPreferences()
Sounds.useApplicationSounds()
let app = NSApplication.shared
let delegate = AppDelegate(browserServices: .shared)
app.delegate = delegate
app.run()

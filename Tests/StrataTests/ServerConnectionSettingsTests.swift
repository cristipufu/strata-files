import AppKit
import Testing
@testable import Strata

struct ServerConnectionSettingsTests {
    private final class Environment {
        let preferences: Prefs
        var defaults: UserDefaults { preferences.defaults }
        let settings: ServerConnectionSettings

        init() throws {
            preferences = try Prefs.isolated()
            settings = ServerConnectionSettings(preferences: preferences)
        }
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    @Test func savedProtocolsAndRecentSharesKeepTheirFormatAndOwner() throws {
        let first = try Environment(), second = try Environment()
        first.defaults.set(["", "smb://one/share", "smb://two/share"], forKey: "recentServers")
        second.defaults.set(["smb://other/share"], forKey: "recentServers")
        second.defaults.set(2, forKey: "connectKind")
        let other = try #require(second.defaults.persistentDomain(forName: second.preferences.domainName))
        #expect(first.settings.kind == .share && second.settings.kind == .s3)
        #expect(first.settings.recents == ["smb://one/share", "smb://two/share"])
        for kind in [ServerConnectionSettings.Kind.share, .sftp, .s3] {
            first.settings.kind = kind
            #expect(first.defaults.integer(forKey: "connectKind") == kind.rawValue)
            let reopened = ServerConnectionSettings(preferences: Prefs(
                defaults: try #require(UserDefaults(suiteName: first.preferences.domainName)),
                domainName: first.preferences.domainName))
            #expect(reopened.kind == kind && reopened.recents == first.settings.recents)
        }
        first.defaults.set(99, forKey: "connectKind")
        #expect(first.settings.kind == .share)
        #expect(first.defaults.integer(forKey: "connectKind") == 99)
        first.settings.clearRecents()
        #expect(first.settings.recents.isEmpty && first.defaults.object(forKey: "recentServers") == nil)
        #expect(first.defaults.integer(forKey: "connectKind") == 99)
        #expect(NSDictionary(dictionary: other).isEqual(to: second.defaults.persistentDomain(forName: second.preferences.domainName) ?? [:]))
        withExtendedLifetime((first, second)) {}
    }

    @Test func rememberingSharesRemovesPasswordsDeduplicatesAndKeepsTheRecentLimit() throws {
        let environment = try Environment()
        for index in 0..<12 {
            let url = try #require(URL(string: "smb://user:fixture-password@host\(index)/share"))
            environment.settings.remember(url)
        }
        let expected = (2..<12).reversed().map { "smb://user@host\($0)/share" }
        #expect(environment.settings.recents == expected)
        #expect(environment.defaults.stringArray(forKey: "recentServers") == expected)
        environment.settings.remember(try #require(URL(string: "smb://user:another-password@HOST5/SHARE")))
        let reordered = ["smb://user@HOST5/SHARE"] + expected.filter { $0 != "smb://user@host5/share" }
        #expect(environment.settings.recents == reordered)
        #expect(environment.defaults.stringArray(forKey: "recentServers") == reordered)
        withExtendedLifetime(environment) {}
    }

    @Test func nativeSheetsReadAndChangeOnlyTheirOwnSettings() throws {
        _ = NSApplication.shared
        let first = try Environment(), second = try Environment()
        first.defaults.set(["smb://one/share"], forKey: "recentServers")
        second.defaults.set(["smb://other/share"], forKey: "recentServers")
        let left = ConnectToServerController(settings: first.settings, mounts: ServerMountSession(mounter: .live), connections: .shared)
        let right = ConnectToServerController(settings: second.settings, mounts: ServerMountSession(mounter: .live), connections: .shared)
        let leftAddress = try #require(views(left.view, of: NSComboBox.self).first)
        let rightAddress = try #require(views(right.view, of: NSComboBox.self).first)
        let picker = try #require(views(left.view, of: NSSegmentedControl.self).first)
        #expect(leftAddress.stringValue == "smb://one/share" && rightAddress.stringValue == "smb://other/share")
        picker.selectedSegment = ServerConnectionSettings.Kind.s3.rawValue
        #expect(picker.sendAction(picker.action, to: picker.target))
        #expect(first.settings.kind == .s3 && second.settings.kind == .share)
        #expect(leftAddress.isHidden && !rightAddress.isHidden)
        picker.selectedSegment = ServerConnectionSettings.Kind.share.rawValue
        #expect(picker.sendAction(picker.action, to: picker.target))
        let clear = try #require(views(left.view, of: NSButton.self).first {
            $0.action == NSSelectorFromString("clearRecents:")
        })
        #expect(clear.sendAction(clear.action, to: clear.target))
        #expect(first.settings.recents.isEmpty && clear.isHidden && leftAddress.numberOfItems == 0)
        #expect(second.settings.recents == ["smb://other/share"] && rightAddress.numberOfItems == 1)
        #expect(rightAddress.stringValue == "smb://other/share")
        let server = RemoteServer(id: UUID().uuidString, kind: .s3, name: "Fixture", host: "s3.eu-west-1.amazonaws.com",
                                  bucket: "fixture", region: "eu-west-1", accessKeyID: "fixture")
        let editing = ConnectToServerController(editing: server, settings: first.settings, mounts: ServerMountSession(mounter: .live), connections: .shared)
        let editPicker = try #require(views(editing.view, of: NSSegmentedControl.self).first)
        #expect(editPicker.isHidden && editPicker.selectedSegment == ServerConnectionSettings.Kind.s3.rawValue)
        #expect(first.settings.kind == .share && first.settings.recents.isEmpty)
        withExtendedLifetime((first, second, left, right, editing)) {}
    }
}

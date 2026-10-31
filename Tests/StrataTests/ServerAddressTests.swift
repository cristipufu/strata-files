import Foundation
import Testing
@testable import Strata
@testable import StrataFiles

struct ServerAddressTests {
    @Test func shareAddressesAcceptOrdinaryTextAndRejectEmbeddedControls() throws {
        for value in ["smb://old/share", "smb://fixture/share", "https://example.invalid/folder", "host/share"] {
            let expected = try #require(URL(string: value.contains("://") ? value : "smb://" + value))
            #expect(ServerConnection.url(from: value) == .success(expected))
        }
        for control in ["\n", "\r", "\t", "\u{0000}", "\u{007f}"] {
            if case .success = ServerConnection.url(from: "smb://fixture/a" + control + "b") {
                Issue.record("A share address accepted an embedded control character")
            }
        }
    }
}

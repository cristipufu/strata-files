import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct JSONPreviewSafetyTests {
    @Test func deeplyNestedJSONStaysAsWritten() {
        let text = String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)
        #expect(JSONFormatter.format(text) == text)
    }

    @Test func indentationCannotMultiplyPreviewMemoryWithoutLimit() {
        let text = String(repeating: "[", count: 60) + String(repeating: "0,", count: 10_000)
            + "0" + String(repeating: "]", count: 60)
        #expect(JSONFormatter.format(text) == text)
    }

    @Test func regularJSONStillFormatsWithoutChangingKeysNumbersOrText() {
        let source = #"{"name":"café 😀","numbers":[1,2.30,4e5],"nested":{"enabled":true}}"#
        let formatted = JSONFormatter.format(source)
        #expect(formatted.contains("\n  \"name\": \"café 😀\","))
        #expect(formatted.contains("[1, 2.30, 4e5]"))
        #expect(formatted.contains("\n    \"enabled\": true\n  }"))
        #expect(JSONFormatter.validate(formatted) == .valid)
    }

    @Test func anIncompleteDeepDocumentAlsoStaysAsWritten() {
        // CodeLoader formats truncated files without requiring complete JSON.
        let text = String(repeating: "[", count: 128) + "0"
        #expect(JSONFormatter.format(text) == text)
    }
}

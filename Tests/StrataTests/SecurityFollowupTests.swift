import AppKit
import Testing
@testable import Strata

struct SecurityFollowupTests {
    private let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    private func header(_ kind: UInt8, count: Int) -> [UInt8] {
        count < 15 ? [kind | UInt8(count)] : [kind | 15, 0x11, UInt8(count >> 8), UInt8(count & 255)]
    }

    private func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return header(0x50, count: bytes.count) + bytes
    }

    /// References deliberately share a single string; the encoded size does not bound the expanded tree.
    private func plist(_ objects: [[UInt8]], top: Int) -> Data {
        var bytes = Array("bplist00".utf8), offsets: [Int] = []
        for object in objects { offsets.append(bytes.count); bytes += object }
        let table = bytes.count
        for offset in offsets { bytes += (0..<4).reversed().map { UInt8(truncatingIfNeeded: offset >> ($0 * 8)) } }
        bytes += [UInt8](repeating: 0, count: 6) + [4, 1]
        for value in [objects.count, top, table] {
            bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(value) >> ($0 * 8)) }
        }
        return Data(bytes)
    }

    private func attribute(_ data: Data, _ name: String, at url: URL) throws {
        try #require(data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) } == 0)
    }

    @Test func sharedPlistBudgetRefusesInvalidLimitsWithoutOverflow() throws {
        let ordinary = try PropertyListSerialization.data(fromPropertyList: "Comment", format: .binary, options: 0)
        for limit in [Int.min, -1, 0, 255, 256] { #expect(!BinaryPropertyListBudget.permits(ordinary, limit: limit)) }
        #expect(BinaryPropertyListBudget.permits(ordinary))
    }

    @Test func tagAttributesRefuseExcessiveSharedStrings() throws {
        let tree = try TestTree("file", "sibling")
        let payload = plist([string(String(repeating: "x", count: 1024)), header(0xA0, count: 130) + [UInt8](repeating: 0, count: 130)], top: 1)
        try attribute(payload, "com.apple.metadata:_kMDItemUserTags", at: tree.url("file"))
        #expect(TagStore.read(tree.url("file").path, labels: []).isEmpty)
        let ordinary = try PropertyListSerialization.data(fromPropertyList: ["Work\n6"], format: .binary, options: 0)
        #expect(TagStore.parse(ordinary, labels: []) == [FinderTag(name: "Work", color: 6)])
        #expect(tree.snapshot() == ["file", "sibling"])
    }

    @Test func bundlePlistsRefuseExcessiveSharedStrings() throws {
        let tree = try TestTree("Fixture.app/Contents/", "sibling")
        let payload = plist([string("CFBundleVersion"), string("5"), string("payload"), string(String(repeating: "x", count: 1024)),
                             header(0xA0, count: 2000) + [UInt8](repeating: 3, count: 2000), [0xD2, 0, 2, 1, 4]], top: 5)
        let info = tree.url("Fixture.app/Contents/Info.plist")
        try payload.write(to: info)
        #expect(InstalledApp.read(tree.url("Fixture.app")).source == .unreadable)
        #expect(try Data(contentsOf: info) == payload)
        let ordinary = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "5"], format: .binary, options: 0)
        try ordinary.write(to: info)
        #expect(InstalledApp.read(tree.url("Fixture.app")).build == "5")
        #expect(tree.snapshot() == ["Fixture.app/", "Fixture.app/Contents/", "Fixture.app/Contents/Info.plist", "sibling"])
    }

    @Test func malformedBinaryCommentsNeverBecomePlainText() throws {
        let tree = try TestTree("file", "sibling")
        try attribute(Data("bplist00not a property list".utf8), commentAttribute, at: tree.url("file"))
        #expect(FileInfoEditing.comment(at: tree.url("file").path).isEmpty)
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let ordinary = try PropertyListSerialization.data(fromPropertyList: "Comment", format: format, options: 0)
            try attribute(ordinary, commentAttribute, at: tree.url("file"))
            #expect(FileInfoEditing.comment(at: tree.url("file").path) == "Comment")
        }
        try attribute(Data("Legacy comment".utf8), commentAttribute, at: tree.url("file"))
        #expect(FileInfoEditing.comment(at: tree.url("file").path) == "Legacy comment")
        #expect(tree.snapshot() == ["file", "sibling"])
    }

    @Test(arguments: ["Changed", ""])
    func commentEditsRefuseItemsReplacedWhileTyping(_ text: String) async throws {
        let tree = try TestTree("file", "sibling")
        let file = tree.url("file")
        try FileInfoEditing.setComment("Original", at: file.path)
        try FileInfoEditing.setComment("Sibling", at: tree.url("sibling").path)
        let editor = InfoEditor(readFacts: InfoEditor.Facts.read(_:opensWithApps:))
        editor.show(try #require(FileEntry(url: file)))
        await editor.factsTask?.value
        let field = try #require(editor.commentsContent.arrangedSubviews.first as? NSTextField)
        editor.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = text
        try FileManager.default.moveItem(at: file, to: tree.url("original"))
        try tree.add(["file"])
        try FileInfoEditing.setComment("Replacement", at: file.path)
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(FileInfoEditing.comment(at: file.path) == "Replacement")
        #expect(FileInfoEditing.comment(at: tree.url("original").path) == "Original")
        #expect(FileInfoEditing.comment(at: tree.url("sibling").path) == "Sibling")
        editor.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = "New edit"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(FileInfoEditing.comment(at: file.path) == "New edit")
        #expect(tree.snapshot() == ["file", "original", "sibling"])
    }

    @Test func commentEditingStillSavesAndCancelsForItsChosenFile() async throws {
        let tree = try TestTree("file", "other")
        try FileInfoEditing.setComment("Before", at: tree.url("file").path)
        try FileInfoEditing.setComment("Other", at: tree.url("other").path)
        let editor = InfoEditor(readFacts: InfoEditor.Facts.read(_:opensWithApps:))
        editor.show(try #require(FileEntry(url: tree.url("file"))))
        await editor.factsTask?.value
        let field = try #require(editor.commentsContent.arrangedSubviews.first as? NSTextField)
        let begin = Notification(name: NSControl.textDidBeginEditingNotification, object: field)
        let end = Notification(name: NSControl.textDidEndEditingNotification, object: field)
        editor.controlTextDidBeginEditing(begin)
        field.stringValue = "Saved"
        editor.controlTextDidEndEditing(end)
        #expect(FileInfoEditing.comment(at: tree.url("file").path) == "Saved")
        editor.controlTextDidBeginEditing(begin)
        field.stringValue = "Cancelled"
        #expect(editor.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        editor.controlTextDidEndEditing(end)
        #expect(FileInfoEditing.comment(at: tree.url("file").path) == "Saved")
        editor.show(try #require(FileEntry(url: tree.url("other"))))
        field.stringValue = "Stale edit"
        editor.controlTextDidEndEditing(end)
        #expect(FileInfoEditing.comment(at: tree.url("other").path) == "Other")
        editor.hide()
        #expect(tree.snapshot() == ["file", "other"])
    }

    @Test(arguments: [false, true])
    func focusedCommentsKeepTheirDisplayedItemBeforeTheFirstEditNotification(_ hide: Bool) async throws {
        _ = NSApplication.shared
        let tree = try TestTree("file", "other")
        let file = tree.url("file")
        try FileInfoEditing.setComment("Original", at: file.path)
        let editor = InfoEditor(readFacts: InfoEditor.Facts.read(_:opensWithApps:))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.commentsContent
        defer { window.close(); window.contentView = nil }
        editor.show(try #require(FileEntry(url: file)))
        await editor.factsTask?.value
        let field = try #require(editor.commentsContent.arrangedSubviews.first as? NSTextField)
        #expect(window.makeFirstResponder(field))
        let nativeEditor = try #require(field.currentEditor() as? NSTextView)
        field.stringValue = "Changed"
        nativeEditor.string = "Changed"
        try FileManager.default.moveItem(at: file, to: tree.url("original"))
        try tree.add(["file"])
        try FileInfoEditing.setComment("Replacement", at: file.path)
        if hide { editor.hide() }
        else { editor.show(try #require(FileEntry(url: tree.url("other")))) }
        #expect(FileInfoEditing.comment(at: file.path) == "Replacement")
        #expect(FileInfoEditing.comment(at: tree.url("original").path) == "Original")
        #expect(FileInfoEditing.comment(at: tree.url("other").path).isEmpty)
        #expect(tree.snapshot() == ["file", "original", "other"])
    }
}

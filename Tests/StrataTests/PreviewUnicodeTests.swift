import AppKit
import Testing
@testable import Strata
@testable import StrataPreviews

@MainActor struct PreviewUnicodeTests {
    private static let documents = [
        "# 中文标题\n\n简体中文、繁體中文、English、日本語、한국어。**粗体** *斜体* `代码` 😀👩🏽‍💻 e\u{301}。\n\n[中文链接](https://example.com/中文)",
        "> # 中文引用\n>\n> | 中文 | 表格😀 |\n> | -- | -- |\n> | 测试 | 👩🏽‍💻 繁體中文 |\n\n- [x] 中文任务\n- [ ] 下一步\n\n```swift\nlet 名称 = \"中文😀\"\n```",
        "# 中文流程\n\n```mermaid\ngraph TD\nA[中文开始] --> B[中文结束]\n```",
        "# 中文长文\n\n" + String(repeating: "中文段落用于检查字体回退、换行以及预览布局。English 😀 e\u{301}。\n\n", count: 350),
    ]

    @Test(arguments: ["utf8", "utf16le", "utf16be"])
    func unicodeDocumentsLoadDrawResizeAndSearch(_ encoding: String) async throws {
        _ = NSApplication.shared
        for original in Self.documents {
            let tree = try TestTree("资料/说明😀.md")
            let data: Data
            switch encoding {
            case "utf16le": data = Data([0xFF, 0xFE]) + (try #require(original.data(using: .utf16LittleEndian)))
            case "utf16be": data = Data([0xFE, 0xFF]) + (try #require(original.data(using: .utf16BigEndian)))
            default: data = Data(original.utf8)
            }
            try data.write(to: tree.url("资料/说明😀.md"))
            let view = MarkdownPreviewView(url: tree.url("资料/说明😀.md"))
            defer { view.cancelLoad() }
            view.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
            view.layoutSubtreeIfNeeded()
            await view.loadingTask?.value
            await view.diagramTask?.value
            #expect(view.textView.string.contains("中文"))
            #expect(view.textView.layoutManager?.backgroundLayoutEnabled == false)
            for width: CGFloat in [280, 720, 1100] {
                view.setFrameSize(NSSize(width: width, height: 900))
                view.layoutSubtreeIfNeeded()
                view.find("中文")
                view.findNext(backwards: false)
                view.findNext(backwards: true)
                view.find("")
                #expect(!view.dataWithPDF(inside: view.bounds).isEmpty)
                #expect(view.textView.renderingError == nil)
            }
            #expect(try Data(contentsOf: tree.url("资料/说明😀.md")) == data)
            #expect(tree.snapshot() == ["资料/", "资料/说明😀.md"])
        }
    }

    @Test func nativeSpaceAndInspectorAcceptAChineseDocument() async throws {
        let tree = try TestTree("说明.md")
        let original = Self.documents[0]
        try Data(original.utf8).write(to: tree.url("说明.md"))
        let environment = try PreviewEnvironment(tree)
        let browser = BrowserViewController(services: environment.services)
        let entry = try #require(FileEntry(url: tree.url("说明.md")))
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { $0.perform() })
        inspector.view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        let rich = try #require(inspector.richPreview as? MarkdownPreviewView)
        await rich.loadingTask?.value
        #expect(rich.textView.string.contains("中文"))
        environment.services.previews.show(entry, from: browser, present: false)
        let content = try #require(environment.services.previews.content)
        await content.session.task?.value
        #expect(content.controls.search.isEnabled)
        content.filter("中文")
        environment.services.previews.close()
        #expect(tree.text("说明.md") == original)
        withExtendedLifetime(environment) {}
    }
}

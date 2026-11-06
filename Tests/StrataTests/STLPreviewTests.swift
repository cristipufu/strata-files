import AppKit
import Testing
import WebKit
@testable import Strata
@testable import StrataPreviews

@MainActor struct STLPreviewTests {
    private static let triangle = """
    solid 中文
    facet normal 0 0 1
      outer loop
        vertex 0 0 0
        vertex 2 0 0
        vertex 0 4 0
      endloop
    endfacet
    endsolid 中文
    """

    @Test func STLNamesChooseTheModelPreviewWithoutReadingTheFile() {
        for name in ["model.stl", "打印模型.STL"] {
            guard case .stl = PreviewFormat(url: URL(fileURLWithPath: "/fixture/" + name), contentType: nil) else {
                Issue.record("STL preview missing"); continue
            }
        }
        #expect(PreviewFormat(url: URL(fileURLWithPath: "/fixture/folder.stl"), contentType: .directory) == nil)
    }

    @Test func realBundledParserHandlesASCIIAndBinaryEvenWithASolidHeader() async throws {
        let context = try await parser()
        defer { context.stopLoading() }
        let ascii = try await result(context, "Uint8Array.from(input).buffer", input: Array(Self.triangle.utf8))
        #expect(ascii == "1|2,4,0|18|true")
        let binary = try await result(context, "binary(1)")
        #expect(binary == ascii)
        #expect(try await result(context, "new TextEncoder().encode('x').buffer") == "invalid")
    }

    @Test func malformedAndOverLimitModelsAreRefusedBeforeMeshAllocation() async throws {
        let context = try await parser()
        defer { context.stopLoading() }
        let cases = [
            "new ArrayBuffer(0)": "invalid",
            "new ArrayBuffer(16*1024*1024 + 1)": "limit",
            "binary(250001)": "limit",
            "binary(0)": "invalid",
            "(() => { const b = binary(1); new DataView(b).setFloat32(96, NaN, true); return b; })()": "invalid",
            "(() => { const b = binary(1); new DataView(b).setUint32(80, 4294967295, true); return b; })()": "invalid",
            "binary(1).slice(0, 133)": "invalid",
        ]
        for (source, expected) in cases { #expect(try await result(context, source) == expected, "\(source)") }
        for text in [Self.triangle.replacingOccurrences(of: "vertex 2", with: "vertex 1e999"),
                     Self.triangle.replacingOccurrences(of: "endfacet", with: ""),
                     Self.triangle + "\ngarbage", "solid a\nendsolid a", "solid a\n" + String(repeating: "x", count: 65)] {
            #expect(try await result(context, "Uint8Array.from(input).buffer", input: Array(text.utf8)) == "invalid")
        }
    }

    @Test func sourceReadsRefuseNonregularAndOversizedFilesWithoutChangingThem() async throws {
        let tree = try TestTree("large.stl", "model.stl")
        try Data(Self.triangle.utf8).write(to: tree.url("model.stl"))
        let handle = try FileHandle(forWritingTo: tree.url("large.stl"))
        try handle.truncate(atOffset: UInt64(ModelDocument.byteLimit + 1))
        try handle.close()
        try #require(mkfifo(tree.url("pipe.stl").path, 0o600) == 0)
        await #expect(throws: (any Error).self) { try await ModelDocument.open(tree.url("large.stl")) }
        await #expect(throws: (any Error).self) { try await ModelDocument.open(tree.url("pipe.stl")) }
        let document = try await ModelDocument.open(tree.url("model.stl"))
        #expect(Data(base64Encoded: document.encoded) == Data(Self.triangle.utf8))
        #expect(tree.snapshot() == ["large.stl", "model.stl", "pipe.stl"])
    }

    @Test func largeInputTravelsAsBoundedResourceBytesInsteadOfALargeNativeScript() async throws {
        let tree = try TestTree("model.stl")
        let data = Data((Self.triangle + String(repeating: " ", count: 2 << 20)).utf8)
        try data.write(to: tree.url("model.stl"))
        let document = try await ModelDocument.open(tree.url("model.stl"))
        let page = try await document.page(settings: .init(background: [0, 0, 0], color: [1, 1, 1], foreground: [1, 1, 1],
            triangles: "Triangles", bounds: "Bounds", reset: "Reset", help: "Help", large: "Large", unavailable: "Unavailable"))
        #expect((page.trustedScript?.utf8.count ?? 0) < 64 << 10)
        guard case .buffered(let read) = page.content else { Issue.record("Model document wasn't buffered"); return }
        let resource = try await read(page.url)
        #expect(resource.data.count > data.count && resource.data.count <= page.limits.bytes)
        await #expect(throws: (any Error).self) { try await read(URL(string: "https://fixture.invalid/model")!) }
        #expect(try Data(contentsOf: tree.url("model.stl")) == data)
        #expect(tree.snapshot() == ["model.stl"])
    }

    @Test func realWebKitRendersWithDocumentScriptsDisabledAndRetiresAfterFailureOrClosing() async throws {
        let tree = try TestTree("model.stl")
        try Data(Self.triangle.utf8).write(to: tree.url("model.stl"))
        let view = ModelPreviewView(url: tree.url("model.stl"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.stop(); window.close(); window.contentView = nil }
        await view.loadingTask?.value
        await view.page.task?.value
        let web = try #require(view.webView)
        do {
            try await wait {
                (try? await javascript(web, "return globalThis.StrataModel?.status")).map { ["ready", "failed"].contains($0) } == true
            }
        } catch {
            let diagnostic = try? await javascript(web, "return JSON.stringify({type: typeof StrataModel, body: document.body?.innerHTML.slice(-600), status: globalThis.StrataModel?.status})")
            Issue.record("STL startup: \(String(describing: diagnostic))")
            throw error
        }
        let state = try await javascript(web, "return [StrataModel.status, StrataModel.failure].join('|')")
        #expect(state == "ready|", "\(String(describing: state))")
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(web.configuration.websiteDataStore.isPersistent == false)
        let stats = try await javascript(web, "return [StrataModel.info.triangles, ...StrataModel.info.dimensions].join('|')")
        #expect(stats == "1|2|4|0")
        let drawing = try await javascript(web, "return String(document.querySelector('canvas').width > 0)")
        #expect(drawing == "true")
        // Simulate WebKit's callback without deliberately crashing a process.
        web.navigationDelegate?.webViewWebContentProcessDidTerminate?(web)
        #expect(view.webView == nil && view.page.task == nil)
        view.open()
        await view.loadingTask?.value
        await view.page.task?.value
        #expect(view.webView != nil)
        window.close()
        #expect(view.webView == nil && view.loadingTask == nil && view.stopped)
        #expect(try String(contentsOf: tree.url("model.stl"), encoding: .utf8) == Self.triangle)
        #expect(tree.snapshot() == ["model.stl"])
    }

    private func parser() async throws -> WKWebView {
        let fixture = """
        function binary(count) {
            const buffer = new ArrayBuffer(84 + count * 50), v = new DataView(buffer);
            for (let i = 0; i < 5; i++) v.setUint8(i, 'solid'.charCodeAt(i));
            v.setUint32(80, count, true);
            if (count > 0) { v.setFloat32(108, 2, true); v.setFloat32(124, 4, true); }
            return buffer;
        }
        """
        return try await ModelPreviewTestSupport.parser("stl", fixture: fixture)
    }

    private func result(_ web: WKWebView, _ source: String, input: [UInt8] = []) async throws -> String {
        let value = try await javascript(web, """
        try {
            const m = StrataModel.parse(\(source));
            return [m.triangles, m.dimensions.join(','), m.vertices.length, [...m.vertices].every(Number.isFinite)].join('|');
        } catch (e) { return e.message; }
        """, arguments: ["input": input])
        return value
    }

    private func javascript(_ web: WKWebView, _ script: String, arguments: [String: Any] = [:]) async throws -> String {
        try await ModelPreviewTestSupport.javascript(web, script, arguments: arguments)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        try await ModelPreviewTestSupport.wait(condition)
    }
}

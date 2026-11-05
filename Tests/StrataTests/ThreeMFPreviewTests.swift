import AppKit
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import Strata
@testable import StrataPreviews

@Suite(.archiveWorkerApp) @MainActor struct ThreeMFPreviewTests {
    private static let core = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
    private static let production = "http://schemas.microsoft.com/3dmanufacturing/production/2015/06"
    private static let mesh = """
    <mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="2" y="0" z="0"/><vertex x="0" y="4" z="0"/></vertices>
    <triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh>
    """

    @Test func namesSelect3MFWithoutIOAndKeepFoldersOut() {
        for name in ["part.3mf", "打印模型.3MF"] {
            for type in [nil, UTType(filenameExtension: "3mf")] {
                guard case .threeMF = PreviewFormat(url: URL(filePath: "/fixture/" + name), contentType: type) else {
                    Issue.record("3MF preview missing"); continue
                }
            }
        }
        #expect(PreviewFormat(url: URL(filePath: "/fixture/folder.3mf"), contentType: .directory) == nil)
    }

    @Test func coreMeshesRespectEveryDeclaredUnitAndNamespacePrefixes() async throws {
        let web = try await ModelPreviewTestSupport.parser("three-mf")
        defer { web.stopLoading() }
        for (unit, symbol) in [("micron", "µm"), ("millimeter", "mm"), ("centimeter", "cm"), ("inch", "in"), ("foot", "ft"), ("meter", "m")] {
            let xml = model(resources: object(1), unit: unit)
            #expect(try await result(web, xml) == "1|2,4,0|\(symbol)|true")
        }
        let prefixed = model(resources: object(1)).replacingOccurrences(of: "<model xmlns=", with: "<m:model xmlns:m=")
            .replacingOccurrences(of: "</model>", with: "</m:model>")
        // A prefixed root does not put unprefixed children in the core namespace.
        #expect(try await result(web, prefixed) == "invalid")
        let alternate = model(resources: object(1)).replacingOccurrences(of: "<", with: "<m:")
            .replacingOccurrences(of: "<m:/", with: "</m:").replacingOccurrences(of: "xmlns=", with: "xmlns:m=")
        #expect(try await result(web, alternate) == "1|2,4,0|mm|true")
    }

    @Test func buildInstancesAndNestedComponentsComposeTransformsInTheSpecifiedOrder() async throws {
        let web = try await ModelPreviewTestSupport.parser("three-mf")
        defer { web.stopLoading() }
        let build = "<item objectid=\"1\"/><item objectid=\"1\" transform=\"0 1 0 -1 0 0 0 0 1 10 0 0\"/>"
        #expect(try await result(web, model(resources: object(1), build: build)) == "2|10,4,0|mm|true")
        let components = "<components><component objectid=\"1\"/><component objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 10 0 0\"/></components>"
        let resources = object(1) + object(2, body: components)
        let instances = "<item objectid=\"2\" transform=\"2 0 0 0 2 0 0 0 2 0 20 0\"/><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 50 0 0\"/>"
        #expect(try await result(web, model(resources: resources, build: instances)) == "3|52,28,0|mm|true")
        let translated = object(1) + object(2, body: "<components><component objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 10 0 0\"/></components>")
        let rotated = "<item objectid=\"1\"/><item objectid=\"2\" transform=\"0 1 0 -1 0 0 0 0 1 0 0 0\"/>"
        #expect(try await result(web, model(resources: translated, build: rotated)) == "2|6,12,0|mm|true")
    }

    @Test func productionPartsKeepTheirIdentityUnitsAndDecodedPackagePaths() async throws {
        let web = try await ModelPreviewTestSupport.parser("three-mf")
        defer { web.stopLoading() }
        let component = "<components><component objectid=\"99\" prod:path=\"/3D/Objects/%E6%89%93%E5%8D%B0%20%E6%A8%A1%E5%9E%8B.model\"/></components>"
        let root = model(resources: object(1, body: component), attributes: "xmlns:prod=\"\(Self.production)\" requiredextensions=\"prod\"")
        let child = model(resources: object(99), build: "", unit: "centimeter")
        #expect(try await result(web, root, extra: ["3D/Objects/打印 模型.model": child]) == "1|20,40,0|mm|true")
        let unusedBuild = model(resources: object(99), build: "<item objectid=\"123456\"/>", unit: "centimeter")
        #expect(try await result(web, root, extra: ["3D/Objects/打印 模型.model": unusedBuild]) == "1|20,40,0|mm|true")
        #expect(try await result(web, root) == "invalid")
    }

    @Test func malformedGraphsCoordinatesXMLAndRequiredExtensionsFailGracefully() async throws {
        let web = try await ModelPreviewTestSupport.parser("three-mf")
        defer { web.stopLoading() }
        let selfReference = object(1, body: "<components><component objectid=\"1\"/></components>")
        let cycle = object(1, body: "<components><component objectid=\"2\"/></components>")
            + object(2, body: "<components><component objectid=\"1\"/></components>")
        let invalid = [
            model(resources: selfReference), model(resources: cycle), model(resources: object(1) + object(1)),
            model(resources: object(1), build: "<item objectid=\"9\"/>"), model(resources: object(1), build: ""),
            model(resources: object(1)).replacingOccurrences(of: "v3=\"2\"", with: "v3=\"3\""),
            model(resources: object(1)).replacingOccurrences(of: "v1=\"0\"", with: "v1=\"-1\""),
            model(resources: object(1)).replacingOccurrences(of: "x=\"2\"", with: "x=\"1e999\""),
            model(resources: object(1), unit: "unknown"),
            model(resources: object(1), build: "<item objectid=\"1\" transform=\"1 0 0\"/>"),
            model(resources: object(1), build: "<item objectid=\"1\" transform=\"1e100 0 0 0 1 0 0 0 1 1e100 0 0\"/>")
                .replacingOccurrences(of: "x=\"2\"", with: "x=\"1e100\""),
            "<!DOCTYPE model [<!ENTITY x 'test'>]>" + model(resources: object(1)),
            "<broken>",
        ]
        for xml in invalid { #expect(try await result(web, xml) == "invalid", "\(xml.prefix(160))") }
        let deep = String(repeating: "<a>", count: 65) + String(repeating: "</a>", count: 65)
        #expect(try await result(web, deep) == "limit")
        let unknown = model(resources: object(1), attributes: "xmlns:custom=\"https://fixture.invalid/extension\" requiredextensions=\"custom\"")
        #expect(try await result(web, unknown) == "unsupported")
    }

    @Test func externalAndAmbiguousPackageTargetsNeverBecomeReads() async throws {
        let web = try await ModelPreviewTestSupport.parser("three-mf")
        defer { web.stopLoading() }
        for target in ["https://fixture.invalid/model", "file:///etc/passwd", "../../outside.model", "%2fsecret.model", "3D/root.model#fragment", "//server/model"] {
            #expect(try await result(web, model(resources: object(1)), relationships: relationships(target: target)) == "invalid")
        }
        #expect(try await result(web, model(resources: object(1)), relationships: relationships(attributes: "TargetMode=\"External\"")) == "invalid")
        let duplicate = relationships().replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"root\" Type=\"other\" Target=\"other\"/></Relationships>")
        #expect(try await result(web, model(resources: object(1)), relationships: duplicate) == "invalid")
    }

    @Test func exponentiallyRepeatedPartsStopBeforeGPUAllocation() async throws {
        let web = try await ModelPreviewTestSupport.parser("three-mf")
        defer { web.stopLoading() }
        var resources = object(1)
        for id in 2...20 { resources += object(id, body: "<components><component objectid=\"\(id - 1)\"/><component objectid=\"\(id - 1)\"/></components>") }
        let payload = try payload(model(resources: resources, build: "<item objectid=\"20\"/>"))
        let state = try await ModelPreviewTestSupport.javascript(web, """
        const original = globalThis.Float32Array;
        globalThis.Float32Array = function() { throw new Error('allocated'); };
        try { StrataModel.parse(new TextEncoder().encode(payload).buffer); return 'unexpected'; }
        catch (error) { return error.message; }
        finally { globalThis.Float32Array = original; }
        """, arguments: ["payload": payload])
        #expect(state == "limit")
    }

    @Test func packagesRefuseOversizedPartsDuplicateNamesAndCancelledReads() async throws {
        let tree = try TestTree("model.3mf", "large.3mf")
        let valid = package(model(resources: object(1)))
        try valid.write(to: tree.url("model.3mf"))
        let document = try await ModelDocument.open(tree.url("model.3mf"), format: .threeMF)
        #expect(Data(base64Encoded: document.encoded) != nil)
        let oversized = await Self.oversizedPackage()
        try oversized.write(to: tree.url("model.3mf"))
        await #expect(throws: (any Error).self) { try await ThreeMFPackage.read(tree.url("model.3mf")) }
        let duplicate = package(model(resources: object(1)), extra: [("3D/root.model", Data("duplicate".utf8))])
        try duplicate.write(to: tree.url("model.3mf"))
        await #expect(throws: (any Error).self) { try await ThreeMFPackage.read(tree.url("model.3mf")) }
        let handle = try FileHandle(forWritingTo: tree.url("large.3mf"))
        try handle.truncate(atOffset: UInt64(ThreeMFPackage.archiveByteLimit + 1)); try handle.close()
        await #expect(throws: (any Error).self) { try await ThreeMFPackage.read(tree.url("large.3mf")) }
        let many = (0...ThreeMFPackage.modelLimit).map { ("3D/\($0).model", Data()) }
        try StoredZIP.make(many).write(to: tree.url("model.3mf"))
        await #expect(throws: (any Error).self) { try await ThreeMFPackage.read(tree.url("model.3mf")) }
        try duplicate.write(to: tree.url("model.3mf"))
        try #require(mkfifo(tree.url("pipe.3mf").path, 0o600) == 0)
        await #expect(throws: (any Error).self) { try await ThreeMFPackage.read(tree.url("pipe.3mf")) }
        let cancelled = Task { try await ThreeMFPackage.read(tree.url("model.3mf")) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try Data(contentsOf: tree.url("model.3mf")) == duplicate)
        #expect(tree.snapshot() == ["large.3mf", "model.3mf", "pipe.3mf"])
    }

    @Test func real3MFWebPreviewRendersOfflineAndEndsOnCloseOrProcessFailure() async throws {
        let tree = try TestTree("模型.3mf")
        let data = package(model(resources: object(1)))
        try data.write(to: tree.url("模型.3mf"))
        let view = ModelPreviewView(url: tree.url("模型.3mf"), format: .threeMF)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.stop(); window.close(); window.contentView = nil }
        await view.loadingTask?.value; await view.page.task?.value
        let web = try #require(view.webView)
        try await ModelPreviewTestSupport.wait { (try? await ModelPreviewTestSupport.javascript(web, "return StrataModel.status")) == "ready" }
        #expect(try await ModelPreviewTestSupport.javascript(web, "return [StrataModel.info.triangles, ...StrataModel.info.dimensions, StrataModel.info.unit].join('|')") == "1|2|4|0|mm")
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript && !web.configuration.websiteDataStore.isPersistent)
        web.navigationDelegate?.webViewWebContentProcessDidTerminate?(web)
        #expect(view.webView == nil && view.page.task == nil)
        view.open(); await view.loadingTask?.value; await view.page.task?.value
        window.close()
        #expect(view.webView == nil && view.loadingTask == nil && view.stopped)
        #expect(try Data(contentsOf: tree.url("模型.3mf")) == data)
        #expect(tree.snapshot() == ["模型.3mf"])
    }

    private func object(_ id: Int, body: String = Self.mesh) -> String { "<object id=\"\(id)\">\(body)</object>" }
    private func model(resources: String, build: String = "<item objectid=\"1\"/>", unit: String = "millimeter", attributes: String = "") -> String {
        "<model xmlns=\"\(Self.core)\" unit=\"\(unit)\" \(attributes)><resources>\(resources)</resources><build>\(build)</build></model>"
    }
    private func relationships(target: String = "/3D/root.model", attributes: String = "") -> String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"root\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\" Target=\"\(target)\" \(attributes)/></Relationships>"
    }
    private func payload(_ xml: String, extra: [String: String] = [:], relationships: String? = nil) throws -> String {
        let parts = ["3D/root.model": xml].merging(extra) { _, new in new }
        let encoded = parts.mapValues { Data($0.utf8).base64EncodedString() }
        let relationships = Data((relationships ?? self.relationships()).utf8).base64EncodedString()
        return String(decoding: try JSONSerialization.data(withJSONObject: ["relationships": relationships, "parts": encoded]), as: UTF8.self)
    }
    private func result(_ web: WKWebView, _ xml: String, extra: [String: String] = [:], relationships: String? = nil) async throws -> String {
        try await ModelPreviewTestSupport.javascript(web, """
        try {
            const mesh = StrataModel.parse(new TextEncoder().encode(payload).buffer);
            return [mesh.triangles, mesh.dimensions.join(','), mesh.unit, [...mesh.vertices].every(Number.isFinite)].join('|');
        } catch (error) { return error.message; }
        """, arguments: ["payload": try payload(xml, extra: extra, relationships: relationships)])
    }
    private func package(_ xml: String, extra: [(String, Data)] = []) -> Data {
        StoredZIP.make([("_rels/.rels", Data(relationships().utf8)), ("3D/root.model", Data(xml.utf8))] + extra)
    }

    @concurrent private static func oversizedPackage() async -> Data {
        StoredZIP.make([("3D/root.model", Data(repeating: 32, count: ModelDocument.byteLimit + 1))])
    }
}

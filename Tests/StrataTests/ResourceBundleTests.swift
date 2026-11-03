import AppKit
import Testing
@testable import StrataSupport
@testable import StrataArchives

private final class ResourceTestMarker: NSObject {}

@MainActor struct ResourceBundleTests {
    private static let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func app(in tree: TestTree, named name: String = "Host.app") throws -> Bundle {
        let info: [String: String] = ["CFBundleIdentifier": "dev.strata.tests.resource-host", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: tree.url("\(name)/Contents/Info.plist"))
        return try #require(Bundle(url: tree.url(name)))
    }

    @Test func packagedResourcesAreFoundInContentsResources() throws {
        let tree = try TestTree("Host.app/Contents/Info.plist", "Host.app/Contents/Resources/Example.bundle/sample.txt")
        let host = try app(in: tree)
        let found = try ResourceBundle.named("Example", in: host, linkedTo: Bundle(for: ResourceTestMarker.self))
        #expect(found.bundleURL.resolvingSymlinksInPath().path == tree.url("Host.app/Contents/Resources/Example.bundle").resolvingSymlinksInPath().path)
        #expect(found.url(forResource: "sample", withExtension: "txt") != nil)
        #expect(tree.snapshot() == ["Host.app/", "Host.app/Contents/", "Host.app/Contents/Info.plist",
            "Host.app/Contents/Resources/", "Host.app/Contents/Resources/Example.bundle/",
            "Host.app/Contents/Resources/Example.bundle/sample.txt"])
    }

    @Test(arguments: ["Host.app", "Host.APP"])
    func missingPackagedResourcesNeverBorrowAnotherBundleOrTheCheckout(_ name: String) throws {
        let tree = try TestTree("\(name)/Contents/Info.plist", "\(name)/Contents/Resources/",
                               "Products/Example.bundle/sample.txt")
        let host = try app(in: tree, named: name)
        let owner = try #require(Bundle(url: tree.url("Products/Example.bundle")))
        #expect(throws: ResourceBundle.Missing.self) { try ResourceBundle.named("Example", in: host, linkedTo: owner) }
        #expect(throws: ResourceBundle.Missing.self) {
            try ResourceBundle.named("Strata_StrataPreviews", in: host, linkedTo: Bundle(for: ResourceTestMarker.self))
        }
        #expect(tree.text("Products/Example.bundle/sample.txt") == "Products/Example.bundle/sample.txt")
    }

    @Test(arguments: ["present", "missing-previews", "missing-themes", "missing-script"])
    func thePackagedProbeLoadsTheReportedDiagramAndMissingAssetsExitNormally(_ condition: String) async throws {
        let tree = try TestTree("Host.app/Contents/Resources/")
        let products = Bundle(for: ResourceTestMarker.self).bundleURL.deletingLastPathComponent()
        let output = try await Self.probe(tree.root, products: products, condition: condition)
        #expect(output.status == (condition == "present" ? 0 : 2), "\(output.output)")
        #expect(!output.timedOut && !output.failed && !output.truncated)
        let text = String(decoding: output.output, as: UTF8.self)
        #expect(text.contains(condition == "present" ? "rendered successfully" : "Packaged resource check failed"))
        #expect(tree.snapshot().contains("Host.app/Contents/Resources/"))
    }

    @concurrent private static func probe(_ root: URL, products: URL, condition: String) async throws -> ProcessRunner.Result {
        let resources = root.appending(path: "Host.app/Contents/Resources")
        for name in ["Strata_StrataPreviews", "Strata_StrataTheme"] {
            let bundle = try ResourceBundle.named(name, in: .main, linkedTo: Bundle(for: ResourceTestMarker.self))
            if condition == "missing-previews" && name == "Strata_StrataPreviews" { continue }
            if condition == "missing-themes" && name == "Strata_StrataTheme" { continue }
            try FileManager.default.copyItem(at: bundle.bundleURL, to: resources.appending(path: name + ".bundle"))
        }
        if condition == "missing-script" {
            let bundle = try #require(Bundle(url: resources.appending(path: "Strata_StrataPreviews.bundle")))
            try FileManager.default.removeItem(at: #require(bundle.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")))
        }
        return try await ProcessRunner.run("/usr/bin/env", ["python3", checkout.appending(path: "scripts/check-app-resources.py").path,
            root.appending(path: "Host.app").path, products.appending(path: "StrataResourceCheck").path,
            checkout.appending(path: "Tests/PreviewDocuments/07-Issue36-Mermaid.md").path], timeout: 55)
    }
}

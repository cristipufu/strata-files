import AppKit
import StrataPreviews
import StrataSupport
import StrataTheme

@main struct StrataResourceCheck {
    enum Invalid: Error { case sample, themes, image }

    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            guard CommandLine.arguments.count == 2 else { throw Invalid.sample }
            guard !(try ThemeCatalog.loadBundled()).isEmpty else { throw Invalid.themes }
            try await modelScripts()
            guard !(try await MathRenderer.script()).isEmpty else { throw Invalid.sample }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            _ = try await MarkdownLoader.load(url)
            let source = try await diagram(url)
            let renderer = MermaidRenderer(script: try await MermaidRenderer.script(), rules: try await HTMLWebSession.contentRules())
            defer { renderer.close() }
            let image = try await renderer.render(source, dark: false)
            guard image.size.width > 0, image.size.height > 0 else { throw Invalid.image }
            print("Packaged themes, model scripts, KaTeX and Mermaid loaded; the Markdown sample rendered successfully.")
        } catch {
            print("Packaged resource check failed: \(error)")
            exit(2)
        }
    }

    @concurrent private static func modelScripts() async throws {
        for name in ["mesh", "stl", "three-mf", "renderer"] {
            guard !(try ModelDocument.bundledScript(name)).isEmpty else { throw Invalid.sample }
        }
    }

    @concurrent private static func diagram(_ url: URL) async throws -> String {
        let blocks = try MarkdownParser.parse(TextFile.read(url).text)
        guard blocks.count == 1, case .code(let language, let source) = blocks[0], language == "mermaid" else { throw Invalid.sample }
        return source
    }
}

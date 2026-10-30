import AppKit
import UniformTypeIdentifiers

/// Native previews for formats Quick Look handles poorly. Returns nil to fall back to Quick Look.
package enum RichPreview {
    /// Decided from the name and type alone, without touching the file.
    package static func canPreview(_ url: URL, contentType: UTType?) -> Bool {
        PreviewFormat(url: url, contentType: contentType) != nil
    }

    /// A view that loads its content off the main thread and fills whatever frame it's given.
    /// `fallback` runs if the file turns out not to suit a rich preview after all (a `.ts` video, a `.db` that isn't
    /// SQLite, binary data under a text extension); show Quick Look then. Without it, the view says "No Preview Available".
    package static func makeView(for url: URL, contentType: UTType?, fallback: (() -> Void)? = nil) -> NSView? {
        guard let format = PreviewFormat(url: url, contentType: contentType) else { return nil }
        let view: PreviewView = switch format {
        case .code(let language): CodePreviewView(url: url, mode: .source(language))
        case .json: CodePreviewView(url: url, mode: .json)
        case .markdown: MarkdownPreviewView(url: url)
        case .html: HTMLPreviewView(url: url)
        case .epub: EPUBPreviewView(url: url)
        case .onenote: OneNotePreviewView(url: url)
        case .onenoteContents: OneNoteContentsView(url: url)
        case .delimited(let separator): DelimitedPreviewView(url: url, separator: separator)
        case .sqlite: SQLitePreviewView(url: url)
        case .archive(let kind): ArchivePreviewView(url: url, kind: kind)
        }
        view.fallback = fallback
        return view
    }
}

/// Which rich preview suits a file, judged by its name and type.
nonisolated package enum PreviewFormat: Sendable {
    case code(Language)
    case json
    case markdown
    case html
    case epub
    case onenote
    case onenoteContents
    /// CSV/TSV; a nil separator is detected from the content.
    case delimited(separator: UInt8?)
    case sqlite
    case archive(ArchiveKind)

    package init?(url: URL, contentType: UTType?) {
        if let contentType, contentType.conforms(to: .directory) || contentType.conforms(to: .package) { return nil }
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "epub" {
            self = .epub
        } else if ext == "one" {
            self = .onenote
        } else if ext == OneNoteContents.fileExtension {
            self = .onenoteContents
        } else if ["html", "htm", "xhtml"].contains(ext) {
            self = .html
        } else if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if Self.jsonExtensions.contains(ext) || name == "package.resolved" || name == ".babelrc" {
            self = .json
        } else if ext == "csv" {
            self = .delimited(separator: nil)
        } else if ext == "tsv" || ext == "tab" {
            self = .delimited(separator: 0x09)
        } else if ext == "psv" {
            self = .delimited(separator: 0x7C)
        } else if Self.sqliteExtensions.contains(ext) {
            self = .sqlite
        } else if let kind = ArchiveKind(fileName: name) {
            self = .archive(kind)
        } else if let language = Languages.detect(fileName: name) {
            self = .code(language)
        } else if let contentType, !contentType.conforms(to: .image), !contentType.conforms(to: .audiovisualContent),
                  [UTType.sourceCode, .script, .shellScript, .xml].contains(where: contentType.conforms(to:)) {
            self = .code(Language(name: contentType.localizedDescription ?? String(localized: "Source", comment: "Fallback name of a source code file type"), lexer: .plain))
        } else if contentType?.conforms(to: .json) == true {
            self = .json
        } else if let contentType, contentType.conforms(to: .plainText) {
            self = .code(Language(name: contentType.localizedDescription ?? String(localized: "Source", comment: "Fallback name of a source code file type"), lexer: .plain))
        } else {
            return nil
        }
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    private static let jsonExtensions: Set<String> = [
        "json", "jsonc", "json5", "geojson", "topojson", "webmanifest", "har", "jsonld", "avsc", "ipynb", "xcstrings",
        "code-workspace", "gltf",
    ]
    private static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "sqlitedb", "gpkg", "mbtiles"]
}

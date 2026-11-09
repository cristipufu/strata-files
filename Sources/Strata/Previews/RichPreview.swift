import StrataArchives
import StrataModel
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
    package static func makeView(for url: URL, contentType: UTType?, preferences: any PreviewTextSettings, clipboard: Clipboard,
                                 media: MediaAnalysisReader = MediaAnalysisReader(), fallback: (() -> Void)? = nil) -> NSView? {
        guard let format = PreviewFormat(url: url, contentType: contentType) else { return nil }
        let view: PreviewView = switch format {
        case .code(let language): CodePreviewView(url: url, mode: .source(language), preferences: preferences)
        case .json: CodePreviewView(url: url, mode: .json, preferences: preferences)
        case .pdf: PDFPreviewView(url: url)
        case .markdown: MarkdownPreviewView(url: url)
        case .notebook: MarkdownPreviewView(notebook: url)
        case .html: HTMLPreviewView(url: url, preferences: preferences)
        case .epub: EPUBPreviewView(url: url)
        case .onenote: OneNotePreviewView(url: url)
        case .onenoteContents: OneNoteContentsView(url: url)
        case .delimited(let separator): DelimitedPreviewView(url: url, separator: separator, clipboard: clipboard)
        case .table(let kind): TablePreviewView(url: url, kind: kind, clipboard: clipboard)
        case .sqlite: SQLitePreviewView(url: url, clipboard: clipboard)
        case .stl: ModelPreviewView(url: url)
        case .threeMF: ModelPreviewView(url: url, format: .threeMF)
        case .xlsx: WorkbookPreviewView(url: url, format: .xlsx, clipboard: clipboard)
        case .ods: WorkbookPreviewView(url: url, format: .ods, clipboard: clipboard)
        case .font: FontPreviewView(url: url)
        case .design: DesignPreviewView(url: url)
        case .geoTrack: GeoTrackPreviewView(url: url)
        case .archive(let kind): ArchivePreviewView(url: url, kind: kind)
        case .video: MediaPreviewView(url: url, type: contentType ?? .movie, reader: media)
        case .audio: MediaPreviewView(url: url, type: contentType ?? .audio, reader: media)
        }
        view.fallback = fallback
        return view
    }
}

/// Which rich preview suits a file, judged by its name and type.
nonisolated package enum PreviewFormat: Sendable {
    case code(Language)
    case json
    case pdf
    case markdown
    case notebook
    case html
    case epub
    case onenote
    case onenoteContents
    /// CSV/TSV; a nil separator is detected from the content.
    case delimited(separator: UInt8?)
    case table(TablePreviewKind)
    case sqlite
    case stl
    case threeMF
    case xlsx
    case ods
    case font
    case design
    case geoTrack
    case archive(ArchiveKind)
    case video
    case audio

    package init?(url: URL, contentType: UTType?) {
        // An alias's extension names its target; the file itself is a bookmark.
        if let contentType, [UTType.directory, .package, .aliasFile].contains(where: contentType.conforms(to:)) { return nil }
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
        } else if ext == "pdf" || contentType?.conforms(to: .pdf) == true {
            self = .pdf
        } else if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if ext == "ipynb" {
            self = .notebook
        } else if ["srt", "vtt"].contains(ext) {
            self = .table(.subtitles)
        } else if ["jsonl", "ndjson"].contains(ext) {
            self = .table(.jsonLines)
        } else if ext == "xcstrings" {
            self = .table(.xcstrings)
        } else if ext == "har" {
            self = .table(.har)
        } else if ext == "parquet" {
            self = .table(.parquet)
        } else if Self.certificateExtensions.contains(ext) {
            self = .table(.certificate)
        } else if Self.mlExtensions.contains(ext) {
            self = .table(.mlHeader)
        } else if Self.fontExtensions.contains(ext) {
            self = .font
        } else if Self.designExtensions.contains(ext) {
            self = .design
        } else if Self.geoTrackExtensions.contains(ext) {
            self = .geoTrack
        } else if Self.jsonExtensions.contains(ext) || name == "package.resolved" || name == ".babelrc" {
            self = .json
        } else if ext == "csv" {
            self = .delimited(separator: nil)
        } else if ext == "tsv" || ext == "tab" {
            self = .delimited(separator: 0x09)
        } else if ext == "psv" {
            self = .delimited(separator: 0x7C)
        } else if ext == "xlsx" {
            self = .xlsx
        } else if ext == "ods" {
            self = .ods
        } else if ext == "stl" {
            self = .stl
        } else if ext == "3mf" {
            self = .threeMF
        } else if Self.sqliteExtensions.contains(ext) {
            self = .sqlite
        } else if let kind = ArchiveKind(fileName: name) {
            self = .archive(kind)
        } else if let language = Languages.detect(fileName: name) {
            self = .code(language)
        } else if contentType?.conforms(to: .movie) == true {
            self = .video
        } else if contentType?.conforms(to: .audio) == true {
            self = .audio
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
        "json", "jsonc", "json5", "topojson", "webmanifest", "jsonld", "avsc",
        "code-workspace", "gltf",
    ]
    private static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "sqlitedb", "gpkg", "mbtiles"]
    private static let certificateExtensions: Set<String> = ["cer", "crt", "der", "pem", "mobileprovision", "provisionprofile"]
    private static let mlExtensions: Set<String> = ["safetensors", "gguf", "npy"]
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "woff"]
    private static let designExtensions: Set<String> = ["sketch", "procreate", "kra", "ora"]
    private static let geoTrackExtensions: Set<String> = ["gpx", "kml", "geojson"]
}

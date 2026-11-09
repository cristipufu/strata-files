import AppKit
import Foundation
import StrataModel
import StrataSupport

nonisolated package enum TablePreviewKind: Sendable, Equatable {
    case subtitles
    case jsonLines
    case xcstrings
    case har
    case parquet
    case certificate
    case mlHeader
}

nonisolated package struct TableDocument: Sendable {
    package let data: GridData
    package let summary: [String]
    package let note: String?
}

package final class TablePreviewView: PreviewView {
    private let grid: GridView

    package override var documentSearch: (any PreviewDocumentSearch)? { grid }

    package init(url: URL, kind: TablePreviewKind, clipboard: Clipboard) {
        grid = GridView(clipboard: clipboard)
        super.init(frame: .zero)
        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(grid)
        NSLayoutConstraint.activate(grid.fillingConstraints(in: contentView))
        load({ try await TableLoader.load(url, kind: kind) }) { [weak self] document in
            guard let self else { return }
            grid.show(document.data)
            footer.show(document.summary, note: document.note)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @objc package override func stop() {
        super.stop()
        grid.stop()
    }
}

nonisolated package enum TableLoader {
    private static let maxRows = 1_000
    private static let maxColumns = 128

    @concurrent package static func load(_ url: URL, kind: TablePreviewKind) async throws -> TableDocument {
        try Task.checkCancellation()
        switch kind {
        case .subtitles:
            return try loadSubtitles(url)
        case .jsonLines:
            return try loadJSONLines(url)
        case .xcstrings:
            return try loadXCStrings(url)
        case .har:
            return try loadHAR(url)
        case .parquet:
            return try loadParquet(url)
        case .certificate:
            return try loadCertificate(url)
        case .mlHeader:
            return try loadMLHeader(url)
        }
    }

    // MARK: - Subtitles (.srt, .vtt)

    private static func loadSubtitles(_ url: URL) throws -> TableDocument {
        let file = try TextFile.read(url)
        let ext = url.pathExtension.lowercased()
        let lines = file.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var rows: [[GridValue]] = []
        var index = 0
        while index < lines.count, rows.count < maxRows {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "WEBVTT" || trimmed.hasPrefix("WEBVTT ") || trimmed.hasPrefix("NOTE") {
                index += 1
                continue
            }
            var cueNumber = "\(rows.count + 1)"
            var timeLine = trimmed
            if !timeLine.contains("-->"), index + 1 < lines.count, lines[index + 1].contains("-->") {
                cueNumber = trimmed
                index += 1
                timeLine = lines[index].trimmingCharacters(in: .whitespaces)
            }
            guard let arrowRange = timeLine.range(of: "-->") else {
                index += 1
                continue
            }
            let start = timeLine[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let endRaw = timeLine[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let end = endRaw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? endRaw
            index += 1
            var textLines: [String] = []
            while index < lines.count {
                let textLine = lines[index].trimmingCharacters(in: .whitespaces)
                if textLine.isEmpty { break }
                let stripped = stripSubtitleTags(textLine)
                if !stripped.isEmpty { textLines.append(stripped) }
                index += 1
            }
            let dialogue = DisplayText.oneLine(textLines.joined(separator: " "))
            rows.append([.text(cueNumber), .text(start), .text(end), .text(dialogue)])
        }

        guard !rows.isEmpty else { throw PreviewError.empty }
        var grid = GridData(
            columns: [
                GridColumn(title: "#", isNumeric: true),
                GridColumn(title: String(localized: "Start")),
                GridColumn(title: String(localized: "End")),
                GridColumn(title: String(localized: "Text")),
            ],
            rows: rows
        )
        grid.measureColumns()
        let formatLabel = ext == "vtt" ? "WebVTT" : "SRT"
        let cueSummary = String(localized: "\(rows.count) cues", comment: "plural")
        let note = file.isTruncated ? String(localized: "Showing first \(TextFile.limitDescription)", comment: "Preview footer note: only the first part is shown (a count or a size)") : nil
        return TableDocument(data: grid, summary: [formatLabel, cueSummary], note: note)
    }

    private static func stripSubtitleTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var inTag = false
        for char in text {
            if char == "<" { inTag = true; continue }
            if char == ">" { inTag = false; continue }
            if !inTag { result.append(char) }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - JSON Lines (.jsonl, .ndjson)

    private static func loadJSONLines(_ url: URL) throws -> TableDocument {
        let file = try TextFile.read(url)
        var columnNames: [String] = []
        var columnIndex: [String: Int] = [:]
        var parsedObjects: [[String: GridValue]] = []
        var truncatedRows = file.isTruncated

        for lineSub in file.text.split(whereSeparator: \.isNewline) {
            let trimmed = lineSub.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if parsedObjects.count >= maxRows {
                truncatedRows = true
                break
            }
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed]) else {
                throw PreviewError.unsupported
            }
            var rowDict: [String: GridValue] = [:]
            if let object = json as? [String: Any] {
                for key in object.keys.sorted() {
                    if columnIndex[key] == nil, columnNames.count < maxColumns {
                        columnIndex[key] = columnNames.count
                        columnNames.append(key)
                    }
                    if let val = object[key] {
                        rowDict[key] = gridValue(from: val)
                    }
                }
            } else {
                let key = "value"
                if columnIndex[key] == nil {
                    columnIndex[key] = columnNames.count
                    columnNames.append(key)
                }
                rowDict[key] = gridValue(from: json)
            }
            parsedObjects.append(rowDict)
        }

        guard !parsedObjects.isEmpty, !columnNames.isEmpty else { throw PreviewError.empty }
        let rows: [[GridValue]] = parsedObjects.map { dict in
            columnNames.map { dict[$0] ?? .null }
        }
        var grid = GridData(
            columns: columnNames.map { GridColumn(title: $0) },
            rows: rows
        )
        grid.detectNumericColumns()
        grid.measureColumns()
        let rowsText = String(localized: "\(rows.count) rows", comment: "plural")
        let colsText = String(localized: "\(columnNames.count) columns", comment: "plural")
        let note = truncatedRows ? String(localized: "First \(rows.count) rows") : nil
        return TableDocument(data: grid, summary: ["JSON Lines", "\(rowsText) × \(colsText)"], note: note)
    }

    private static func gridValue(from any: Any) -> GridValue {
        if any is NSNull { return .null }
        if let string = any as? String { return .text(DisplayText.oneLine(string)) }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? "true" : "false")
            }
            return .text(number.stringValue)
        }
        if let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return .text(DisplayText.oneLine(text))
        }
        return .text(DisplayText.oneLine(String(describing: any)))
    }

    // MARK: - Xcode String Catalogs (.xcstrings)

    private static func loadXCStrings(_ url: URL) throws -> TableDocument {
        let (data, truncated) = try TextFile.readPrefix(url, limit: 8 << 20)
        guard !truncated,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            throw PreviewError.unsupported
        }
        let sourceLang = (root["sourceLanguage"] as? String) ?? "en"
        var languagesSet: Set<String> = [sourceLang]
        for (_, entryAny) in strings {
            guard let entry = entryAny as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            for lang in localizations.keys where languagesSet.count < 32 {
                languagesSet.insert(lang)
            }
        }
        let languages = [sourceLang] + languagesSet.subtracting([sourceLang]).sorted()
        let sortedKeys = strings.keys.sorted()
        var rows: [[GridValue]] = []
        for key in sortedKeys.prefix(maxRows) {
            guard let entry = strings[key] as? [String: Any] else { continue }
            let comment = (entry["comment"] as? String).map(DisplayText.oneLine) ?? ""
            let localizations = entry["localizations"] as? [String: Any]
            var row: [GridValue] = [.text(DisplayText.oneLine(key)), .text(comment)]
            for lang in languages {
                let text = extractXCStringsValue(localizations?[lang], fallback: lang == sourceLang ? key : nil)
                row.append(text.map { .text(DisplayText.oneLine($0)) } ?? .null)
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { throw PreviewError.empty }
        let columns = [GridColumn(title: String(localized: "Key")), GridColumn(title: String(localized: "Comment"))]
            + languages.map { GridColumn(title: $0) }
        var grid = GridData(columns: columns, rows: rows)
        grid.measureColumns()
        let keysLabel = String(localized: "\(strings.count) keys", comment: "plural")
        let langsLabel = String(localized: "\(languages.count) languages", comment: "plural")
        let note = strings.count > maxRows ? String(localized: "First \(maxRows) rows") : nil
        return TableDocument(data: grid, summary: ["String Catalog", keysLabel, langsLabel], note: note)
    }

    private static func extractXCStringsValue(_ locAny: Any?, fallback: String?) -> String? {
        guard let loc = locAny as? [String: Any] else { return fallback }
        if let stringUnit = loc["stringUnit"] as? [String: Any],
           let val = stringUnit["value"] as? String {
            return val
        }
        if let variations = loc["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: Any] {
            for form in ["other", "one", "zero", "two", "few", "many"] {
                if let branch = plural[form] as? [String: Any],
                   let unit = branch["stringUnit"] as? [String: Any],
                   let val = unit["value"] as? String {
                    return val
                }
            }
        }
        return fallback
    }

    // MARK: - HTTP Archive (.har)

    private static func loadHAR(_ url: URL) throws -> TableDocument {
        let (data, truncated) = try TextFile.readPrefix(url, limit: 16 << 20)
        guard !truncated,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else {
            throw PreviewError.unsupported
        }
        var rows: [[GridValue]] = []
        for entry in entries.prefix(maxRows) {
            let request = entry["request"] as? [String: Any]
            let response = entry["response"] as? [String: Any]
            let method = (request?["method"] as? String) ?? "GET"
            let urlString = (request?["url"] as? String) ?? ""
            let components = URLComponents(string: urlString)
            let host = components?.host ?? ""
            let path = components?.path.isEmpty == false ? components!.path : urlString
            let status = safeHARInt(response?["status"]) ?? 0
            let content = response?["content"] as? [String: Any]
            let mime = (content?["mimeType"] as? String)?.split(separator: ";").first.map(String.init) ?? ""
            let bodySize = safeHARInt64(content?["size"])
                ?? safeHARInt64(response?["bodySize"]) ?? 0
            let rawTime = (entry["time"] as? NSNumber)?.doubleValue ?? 0
            let timeMs: Int? = (rawTime.isFinite && rawTime > 0 && rawTime < 1_000_000_000)
                ? Int(rawTime.rounded())
                : nil

            rows.append([
                .text(method),
                status > 0 ? .text("\(status)") : .null,
                .text(host),
                .text(DisplayText.oneLine(path)),
                .text(mime),
                bodySize > 0 ? .text(ByteCountFormatter.string(fromByteCount: bodySize, countStyle: .file)) : .text("0 B"),
                timeMs.map { .text("\($0) ms") } ?? .null,
            ])
        }
        guard !rows.isEmpty else { throw PreviewError.empty }
        var grid = GridData(
            columns: [
                GridColumn(title: String(localized: "Method")),
                GridColumn(title: String(localized: "Status"), isNumeric: true),
                GridColumn(title: String(localized: "Host")),
                GridColumn(title: String(localized: "Path")),
                GridColumn(title: String(localized: "Type")),
                GridColumn(title: String(localized: "Size")),
                GridColumn(title: String(localized: "Time")),
            ],
            rows: rows
        )
        grid.measureColumns()
        let reqLabel = String(localized: "\(entries.count) requests", comment: "plural")
        let note = entries.count > maxRows ? String(localized: "First \(maxRows) rows") : nil
        return TableDocument(data: grid, summary: ["HAR", reqLabel], note: note)
    }

    private static func safeHARInt(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        guard let num = raw as? NSNumber else { return nil }
        let d = num.doubleValue
        guard d.isFinite, d >= 0, d <= Double(Int32.max) else { return nil }
        return Int(d.rounded())
    }

    private static func safeHARInt64(_ raw: Any?) -> Int64? {
        if let i = raw as? Int64 { return i }
        if let i = raw as? Int { return Int64(i) }
        guard let num = raw as? NSNumber else { return nil }
        let d = num.doubleValue
        guard d.isFinite, d >= 0, d <= 1e15 else { return nil }
        return Int64(d.rounded())
    }

    // MARK: - Apache Parquet (.parquet)

    private static func loadParquet(_ url: URL) throws -> TableDocument {
        guard let schema = ParquetMetadata.read(url), !schema.columns.isEmpty else {
            throw PreviewError.unsupported
        }
        let rows: [[GridValue]] = schema.columns.map { col in
            [
                .text(col.name),
                .text(col.physicalType),
                col.logicalType.map { .text($0) } ?? .null,
                .text(col.repetition),
            ]
        }
        var grid = GridData(
            columns: [
                GridColumn(title: String(localized: "Column")),
                GridColumn(title: String(localized: "Type")),
                GridColumn(title: String(localized: "Logical Type")),
                GridColumn(title: String(localized: "Repetition")),
            ],
            rows: rows
        )
        grid.measureColumns()
        let rowsLabel = String(localized: "\(Int(schema.rowCount)) rows", comment: "plural")
        let colsLabel = String(localized: "\(schema.columns.count) columns", comment: "plural")
        return TableDocument(data: grid, summary: ["Parquet", "\(rowsLabel) × \(colsLabel)"], note: schema.createdBy)
    }

    // MARK: - Certificates & Provisioning Profiles

    private static func loadCertificate(_ url: URL) throws -> TableDocument {
        guard let cert = CertificateMetadata.read(url) else {
            throw PreviewError.unsupported
        }
        var pairs: [(String, String)] = []
        if let subject = cert.subject { pairs.append((String(localized: "Issued to"), subject)) }
        if let org = cert.organization { pairs.append((String(localized: "Organization"), org)) }
        if let issuer = cert.issuer { pairs.append((String(localized: "Issued by"), issuer)) }
        if let team = cert.team { pairs.append((String(localized: "Team"), team)) }
        if let appID = cert.appID { pairs.append((String(localized: "App ID"), appID)) }
        if let validFrom = cert.validFrom {
            pairs.append((String(localized: "Valid from"), validFrom.formatted(date: .abbreviated, time: .shortened)))
        }
        if let expires = cert.expires {
            let dateText = expires.formatted(date: .abbreviated, time: .shortened)
            pairs.append((String(localized: "Expires"), cert.isExpired ? String(localized: "\(dateText) (Expired)") : dateText))
        }
        if !cert.domains.isEmpty {
            pairs.append((String(localized: "Domains"), cert.domains.joined(separator: ", ")))
        }
        if !cert.platforms.isEmpty {
            pairs.append((String(localized: "Platforms"), cert.platforms.joined(separator: ", ")))
        }
        if let devices = cert.provisionedDeviceCount {
            pairs.append((String(localized: "Provisioned devices"), devices.formatted()))
        }
        if let uuid = cert.uuid {
            pairs.append(("UUID", uuid))
        }
        guard !pairs.isEmpty else { throw PreviewError.unsupported }
        var grid = GridData(
            columns: [
                GridColumn(title: String(localized: "Field")),
                GridColumn(title: String(localized: "Value")),
            ],
            rows: pairs.map { [.text($0.0), .text($0.1)] }
        )
        grid.measureColumns()
        let kindLabel = cert.isProvisioningProfile
            ? String(localized: "Provisioning Profile")
            : String(localized: "Certificate")
        return TableDocument(data: grid, summary: [kindLabel], note: nil)
    }

    // MARK: - ML Weights & NumPy (.safetensors, .gguf, .npy)

    private static func loadMLHeader(_ url: URL) throws -> TableDocument {
        guard let details = MLHeaderMetadata.read(url) else {
            throw PreviewError.unsupported
        }
        if details.format == "NumPy" {
            var rows: [[GridValue]] = []
            if !details.sampleValues.isEmpty {
                rows = details.sampleValues.enumerated().map { idx, val in
                    [.text("\(idx)"), .text(val)]
                }
            } else {
                rows = [
                    [.text(String(localized: "Shape")), .text(details.shapeDescription ?? "—")],
                    [.text(String(localized: "Precision")), .text(details.precision ?? "—")],
                ]
            }
            var grid = GridData(
                columns: !details.sampleValues.isEmpty
                    ? [GridColumn(title: "#", isNumeric: true), GridColumn(title: String(localized: "Value"), isNumeric: true)]
                    : [GridColumn(title: String(localized: "Field")), GridColumn(title: String(localized: "Value"))],
                rows: rows
            )
            grid.measureColumns()
            let summary = ["NumPy", details.shapeDescription, details.precision].compactMap { $0 }
            return TableDocument(data: grid, summary: summary, note: nil)
        }

        let rows: [[GridValue]] = details.tensors.map { tensor in
            let shapeText = "[" + tensor.shape.map(String.init).joined(separator: ", ") + "]"
            return [
                .text(tensor.name),
                .text(shapeText),
                .text(tensor.dtype),
                .text(tensor.parameters.formatted()),
            ]
        }
        guard !rows.isEmpty else { throw PreviewError.empty }
        var grid = GridData(
            columns: [
                GridColumn(title: String(localized: "Tensor")),
                GridColumn(title: String(localized: "Shape")),
                GridColumn(title: String(localized: "Precision")),
                GridColumn(title: String(localized: "Parameters"), isNumeric: true),
            ],
            rows: rows
        )
        grid.measureColumns()
        var summary = [details.format]
        if let arch = details.architecture { summary.append(arch) }
        if let precision = details.precision { summary.append(precision) }
        summary.append(String(localized: "\(details.tensors.count) tensors", comment: "plural"))
        return TableDocument(data: grid, summary: summary, note: details.modelName)
    }
}

import AppKit
import CPreviewText
import Foundation
import StrataModel
import StrataSupport

nonisolated package enum NotebookLoader {
    package static let byteLimit = 8 << 20
    package static let cellLimit = 200
    package static let maxOutputsPerCell = 16
    package static let maxTotalOutputs = 128
    private static let imageLimit = 12
    private static let cellTextLimit = 32_000
    package static let totalTextLimit = 128_000
    private static let outputTextLimit = 4_000

    @concurrent package static func load(_ url: URL) async throws -> MarkdownDocument {
        try Task.checkCancellation()
        let (data, truncated) = try TextFile.readPrefix(url, limit: byteLimit)
        guard !truncated,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]] else {
            throw PreviewError.unsupported
        }
        guard !cells.isEmpty else { throw PreviewError.empty }

        let metadata = root["metadata"] as? [String: Any]
        let kernelspec = metadata?["kernelspec"] as? [String: Any]
        let languageInfo = metadata?["language_info"] as? [String: Any]
        let rawLanguage = (languageInfo?["name"] as? String)
            ?? (kernelspec?["language"] as? String)
            ?? "python"
        let trimmedLanguage = DisplayText.oneLine(String(rawLanguage.unicodeScalars.prefix(32)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fenceLang = trimmedLanguage.isEmpty ? "python" : trimmedLanguage.lowercased()
        let rawDisplay = (kernelspec?["display_name"] as? String) ?? fenceLang.capitalized
        let trimmedDisplay = DisplayText.oneLine(String(rawDisplay.unicodeScalars.prefix(48)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLanguage = trimmedDisplay.isEmpty ? "Python" : trimmedDisplay

        let combined = NSMutableAttributedString()
        let baseURL = url.deletingLastPathComponent()
        let renderer = MarkdownRenderer(baseURL: baseURL)
        var imageCount = 0
        var totalOutputs = 0

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        var isTruncatedByLength = false
        cellLoop: for cell in cells.prefix(cellLimit) {
            try Task.checkCancellation()
            if combined.length >= totalTextLimit {
                isTruncatedByLength = true
                break
            }
            let cellType = (cell["cell_type"] as? String) ?? "markdown"
            let rawSource = joinedLines(cell["source"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let source = rawSource.count > cellTextLimit
                ? String(rawSource.prefix(cellTextLimit)) + "\n…"
                : rawSource

            if combined.length > 0, !source.isEmpty {
                combined.append(NSAttributedString(string: "\n\n"))
            }

            switch cellType {
            case "markdown", "raw":
                guard !source.isEmpty else { continue }
                do {
                    let blocks = try MarkdownParser.parse(source)
                    try renderer.append(blocks, into: combined)
                } catch is CancellationError {
                    throw CancellationError()
                } catch is MarkdownLimitExceeded {
                    isTruncatedByLength = true
                    break cellLoop
                } catch {
                    combined.append(NSAttributedString(string: source, attributes: CodeTheme.baseAttributes()))
                }

            case "code":
                let execCount = safeExecutionCount(cell["execution_count"])
                let prompt = execCount.map { "In [\($0)]:\n" } ?? "In [ ]:\n"
                if !source.isEmpty {
                    combined.append(NSAttributedString(string: prompt, attributes: labelAttributes))
                    do {
                        try renderer.append([.code(language: fenceLang, text: source)], into: combined)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch is MarkdownLimitExceeded {
                        isTruncatedByLength = true
                        break cellLoop
                    } catch {
                        combined.append(NSAttributedString(string: source, attributes: CodeTheme.baseAttributes()))
                    }
                }

                if let outputs = cell["outputs"] as? [[String: Any]] {
                    if outputs.count > maxOutputsPerCell {
                        isTruncatedByLength = true
                    }
                    for output in outputs.prefix(maxOutputsPerCell) {
                        try Task.checkCancellation()
                        if combined.length >= totalTextLimit || totalOutputs >= maxTotalOutputs {
                            isTruncatedByLength = true
                            break cellLoop
                        }
                        var producedOutput = false
                        if let textOut = extractOutputText(output) {
                            producedOutput = true
                            let clipped = textOut.count > outputTextLimit
                                ? String(textOut.prefix(outputTextLimit)) + "\n…"
                                : textOut
                            combined.append(NSAttributedString(string: "\n"))
                            do {
                                try renderer.append([.code(language: "text", text: clipped)], into: combined)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch is MarkdownLimitExceeded {
                                isTruncatedByLength = true
                                break cellLoop
                            } catch {
                                combined.append(NSAttributedString(string: clipped, attributes: CodeTheme.baseAttributes()))
                            }
                        }
                        if imageCount < imageLimit,
                           let imageAttachment = extractOutputImage(output) {
                            producedOutput = true
                            imageCount += 1
                            combined.append(NSAttributedString(string: "\n"))
                            combined.append(imageAttachment)
                        }
                        if producedOutput {
                            totalOutputs += 1
                        }
                    }
                }

            default:
                break
            }
        }

        guard combined.length > 0 else { throw PreviewError.empty }
        try Task.checkCancellation()
        let words = (try? STPreviewTextBuilder.wordCount(in: combined.string).intValue) ?? 0
        guard let storage = STCreatePreviewTextStorage(combined) else { throw PreviewError.unsupported }
        let cellsLabel = String(localized: "\(cells.count) cells", comment: "plural")
        return MarkdownDocument(
            storage: Handoff(value: storage),
            tables: Handoff(value: renderer.tables),
            wordCount: words,
            isTruncated: cells.count > cellLimit || isTruncatedByLength,
            isSource: false,
            customSummary: ["Notebook", displayLanguage, cellsLabel]
        )
    }

    private static func safeExecutionCount(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i >= 0 ? i : nil }
        guard let num = raw as? NSNumber else { return nil }
        let d = num.doubleValue
        guard d.isFinite, d >= 0, d <= Double(Int32.max), d.rounded() == d else { return nil }
        return Int(d)
    }

    private static func joinedLines(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let lines = value as? [String] { return lines.joined() }
        if let anyArray = value as? [Any] {
            return anyArray.compactMap { $0 as? String }.joined()
        }
        return ""
    }

    private static func extractOutputText(_ output: [String: Any]) -> String? {
        let outputType = (output["output_type"] as? String) ?? ""
        switch outputType {
        case "stream":
            let text = joinedLines(output["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case "execute_result", "display_data":
            guard let data = output["data"] as? [String: Any] else { return nil }
            let text = joinedLines(data["text/plain"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case "error":
            let ename = (output["ename"] as? String) ?? "Error"
            let evalue = (output["evalue"] as? String) ?? ""
            return evalue.isEmpty ? ename : "\(ename): \(evalue)"
        default:
            return nil
        }
    }

    private static func extractOutputImage(_ output: [String: Any]) -> NSAttributedString? {
        guard let dataDict = output["data"] as? [String: Any] else { return nil }
        let base64String = joinedLines(dataDict["image/png"]).isEmpty
            ? joinedLines(dataDict["image/jpeg"])
            : joinedLines(dataDict["image/png"])
        let cleanBase64 = base64String.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !cleanBase64.isEmpty, cleanBase64.utf8.count <= (8 << 20),
              let imageData = Data(base64Encoded: cleanBase64),
              let picture = try? PreviewPicture(imageData),
              let cgImage = try? picture.thumbnail(pixels: 960) else { return nil }

        let maxDisplayWidth: CGFloat = 520
        let scale = cgImage.width > 0 ? min(1.0, maxDisplayWidth / CGFloat(cgImage.width)) : 1.0
        let size = NSSize(width: max(1, CGFloat(cgImage.width) * scale), height: max(1, CGFloat(cgImage.height) * scale))
        let nsImage = NSImage(cgImage: cgImage, size: size)
        let attachment = NSTextAttachment()
        attachment.image = nsImage
        attachment.bounds = NSRect(origin: .zero, size: size)
        return NSAttributedString(attachment: attachment)
    }
}

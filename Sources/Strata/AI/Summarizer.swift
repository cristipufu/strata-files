import Foundation
import FoundationModels

/// A one-line title and a few bullets about a document.
package nonisolated struct DocumentSummary: Sendable, Hashable {
    package enum Method: String, Sendable {
        /// Written by the on-device model.
        case model
        /// Picked from the document's own sentences (no model).
        case keySentences
    }

    package var title: String
    package var bullets: [String]
    package var method: Method
    /// False while tokens are still streaming in.
    package var isComplete: Bool
    /// What was left out or why the fallback was used ("Summarised from the first 20 of 48 pages").
    package var note: String?
    /// Progress while condensing a long document ("Reading part 2 of 4…").
    package var status: String?
}

/// Summarises documents into a title and 3–5 bullets.
///
/// With Apple Intelligence: the text is fitted to the model's context window (4,096 tokens shared by instructions, document and
/// answer). Short documents go in one pass; long ones are condensed part by part first (map-reduce), then summarised. The final
/// pass streams, so the title and bullets appear as they're generated. The output shape is enforced by guided generation.
///
/// Without it (or if the model refuses): the most representative sentences of the document, chosen by word frequency and position.
package nonisolated enum Summarizer {
    package static func canSummarize(_ url: URL) -> Bool {
        TextExtractor.canExtract(url)
    }

    package static func summarize(url: URL, preferModel: Bool = true) -> AsyncThrowingStream<DocumentSummary, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let extracted = await TextExtractor.extract(url, options: TextExtractor.Options(maxCharacters: 60_000, maxPDFPages: 30)) else {
                    continuation.finish(throwing: SummaryError.noText)
                    return
                }
                var note: String?
                if extracted.truncated, let pages = extracted.pageCount, pages > extracted.pageStarts.count {
                    note = String(localized: "Summarised from the first \(extracted.pageStarts.count.formatted()) of \(pages) pages", comment: "plural")
                } else if extracted.truncated {
                    note = String(localized: "Summarised from the beginning of the document")
                }
                // Metadata title, else the document's own heading, else the file name.
                let title = extracted.title ?? heading(extracted.text) ?? url.deletingPathExtension().lastPathComponent
                do {
                    for try await summary in summarize(text: extracted.text, titleHint: title, preferModel: preferModel) {
                        var summary = summary
                        if summary.note == nil { summary.note = note }
                        continuation.yield(summary)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    package static func summarize(text: String, titleHint: String?, preferModel: Bool = true) -> AsyncThrowingStream<DocumentSummary, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let fallback = keySentences(text: text, titleHint: titleHint)
                guard preferModel, AIModel.isAvailable else {
                    continuation.yield(fallback)
                    continuation.finish()
                    return
                }
                do {
                    try await modelSummary(text: text, titleHint: titleHint) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    // Refusals, guardrails, an overfull context: still show something useful, and say why.
                    var summary = fallback
                    // The reason is a sentence of its own (never lowercased: German nouns, names…).
                    let reason = AIErrorText.describe(error)
                    summary.note = String(localized: "Apple Intelligence couldn’t summarise this. \(reason)", comment: "Then a sentence saying why, like “The on-device model is busy.”")
                    continuation.yield(summary)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Model

    package static func schema() throws -> GenerationSchema {
        try Schema.root(Schema.object("Summary", nil, [
            Schema.field("title", "A specific title for the document, at most 8 words", Schema.string()),
            Schema.field("bullets", "The key points: concrete facts, names, amounts, dates and decisions; one short sentence each",
                         Schema.array(Schema.string(), min: 3, max: 5)),
        ]))
    }

    package static let instructions = """
    You summarise documents for the preview pane of a Mac file manager. Write a specific title and 3 to 5 short bullets with the \
    most useful concrete facts. No preamble, no opinions. Write in the document's language.
    """

    /// Characters of document text that fit one request, leaving room for instructions, schema and answer.
    package static var characterBudget: Int {
        let tokens = max(1000, AIModel.contextSize - 900)
        return tokens * 3  // ~3 characters per token is conservative for English prose.
    }

    package static func modelSummary(text: String, titleHint: String?, yield: @Sendable (DocumentSummary) -> Void) async throws {
        var body = text
        var note: String?
        if body.count > characterBudget {
            let parts = sections(body, size: characterBudget, limit: 6)
            if parts.total > parts.kept.count {
                note = String(localized: "Summarised from \(parts.kept.count.formatted()) of \(parts.total) parts", comment: "plural")
            }
            var notes: [String] = []
            for (index, part) in parts.kept.enumerated() {
                try Task.checkCancellation()
                yield(DocumentSummary(title: titleHint ?? "", bullets: [], method: .model, isComplete: false, note: note,
                                      status: String(localized: "Reading part \(index + 1) of \(parts.kept.count)…")))
                let session = LanguageModelSession(instructions: "You condense part of a longer document into notes for a later summary.")
                let response = try await session.respond(
                    to: "Condense this part into 3 short sentences keeping names, numbers, dates and decisions:\n\n\(part)",
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 180))
                notes.append(response.content)
            }
            body = notes.enumerated().map { "Part \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        }
        body = try await fitted(body)

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Document\(titleHint.map { " “\($0)”" } ?? ""):\n\n\(body)"
        let stream = session.streamResponse(to: prompt, schema: try schema(),
                                            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 420))
        var last = DocumentSummary(title: titleHint ?? "", bullets: [], method: .model, isComplete: false, note: note)
        for try await snapshot in stream {
            let content = snapshot.rawContent
            last.title = content["title"]?.string ?? last.title
            last.bullets = content["bullets"]?.array.compactMap(\.string).filter { !$0.isEmpty } ?? last.bullets
            last.status = nil
            yield(last)
        }
        last.isComplete = true
        last.title = last.title.trimmingCharacters(in: .whitespacesAndNewlines)
        last.bullets = last.bullets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        yield(last)
    }

    /// Trims text to the context budget; on macOS 26.4+ checks the real token count.
    package static func fitted(_ text: String) async throws -> String {
        var body = String(text.prefix(characterBudget))
        if #available(macOS 26.4, *) {
            let budget = max(1000, AIModel.contextSize - 900)
            for _ in 0..<3 {
                let tokens = try await SystemLanguageModel.default.tokenCount(for: body)
                guard tokens > budget else { break }
                // Typed steps: as one mixed Int/Double expression this took the compiler over a second.
                let scaled: Double = Double(body.count) * Double(budget) / Double(tokens) * 0.95
                let keep = Int(scaled)
                body = String(body.prefix(keep))
            }
        }
        return body
    }

    /// Splits on paragraph boundaries into parts of at most `size` characters; keeps the first, last and evenly spaced
    /// middle parts when there are more than `limit`.
    package static func sections(_ text: String, size: Int, limit: Int) -> (kept: [String], total: Int) {
        // Non-positive sizes or limits keep no sections.
        guard size > 0, limit > 0 else { return ([], 0) }
        var parts: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            if current.count + paragraph.count + 1 > size, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            if paragraph.count > size {
                var rest = Substring(paragraph)
                while rest.count > size {
                    parts.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + paragraph
            }
        }
        if !current.isEmpty { parts.append(current) }
        guard parts.count > limit else { return (parts, parts.count) }
        guard limit > 1 else { return ([parts[0]], parts.count) }
        // First, last and evenly spaced parts in between, each once and in order.
        let step: Double = Double(parts.count - 1) / Double(limit - 1)
        var seen = Set<Int>()
        var kept: [String] = []
        for i in 0..<limit {
            let index = Int((Double(i) * step).rounded())
            if seen.insert(index).inserted { kept.append(parts[index]) }
        }
        return (kept, parts.count)
    }

    // MARK: - Key sentences

    /// An extractive summary: the most representative sentences, in document order.
    package static func keySentences(text: String, titleHint: String?, count: Int = 4) -> DocumentSummary {
        let segments = TextChunker.segments(String(text.prefix(60_000)))
        let title = bestTitle(segments.map(\.text), hint: titleHint)

        var frequency: [String: Int] = [:]
        for segment in segments { for stem in Terms.normalize(segment.text) { frequency[stem, default: 0] += 1 } }
        let top = Double(frequency.values.max() ?? 1)

        struct Candidate {
            let index: Int
            let text: String
            let stems: Set<String>
            let score: Double
        }
        var candidates: [Candidate] = []
        for (index, segment) in segments.enumerated() {
            let display = SemanticIndex.displayText(segment.text)
            let letters = display.filter(\.isLetter).count
            guard display.count >= 25, display.count <= 400, Double(letters) / Double(display.count) > 0.55,
                  display.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else { continue }
            let stems = Set(Terms.normalize(display))
            guard stems.count >= 3 else { continue }
            var score = stems.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) / top } / Double(stems.count).squareRoot()
            if index < 3 { score *= 1.25 - Double(index) * 0.05 }
            if display.contains(where: \.isNumber) { score *= 1.1 }
            if display.count < 45 { score *= 0.75 }
            candidates.append(Candidate(index: index, text: display, stems: stems, score: score))
        }
        let titleStems = Set(Terms.normalize(title))
        var picked: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            // A line that just restates the title adds nothing.
            if !titleStems.isEmpty, Double(candidate.stems.intersection(titleStems).count) / Double(candidate.stems.count) > 0.6 { continue }
            if picked.count == count { break }
            let redundant = picked.contains { other in
                Double(other.stems.intersection(candidate.stems).count) / Double(other.stems.union(candidate.stems).count) > 0.5
            }
            if !redundant { picked.append(candidate) }
        }
        let bullets = picked.sorted { $0.index < $1.index }.map { shorten($0.text, to: 200) }
        return DocumentSummary(title: title, bullets: bullets, method: .keySentences, isComplete: true)
    }

    private static func bestTitle(_ lines: [String], hint: String?) -> String {
        if let hint, !hint.isEmpty { return hint }
        return lines.first.map { shorten(SemanticIndex.displayText($0), to: 80) } ?? String(localized: "Untitled", comment: "Title of a document summary when the document has none")
    }

    /// A short first line that reads like a heading ("Q3 Planning Offsite — Summary").
    package static func heading(_ text: String) -> String? {
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map({ SemanticIndex.displayText(String($0)) }),
              line.count >= 3, line.count <= 80, !line.hasSuffix("."), !line.hasSuffix(":"), line.filter(\.isLetter).count >= 3 else { return nil }
        return line
    }

    package static func shorten(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—")) + "…"
    }
}

package nonisolated enum SummaryError: LocalizedError {
    case noText

    package var errorDescription: String? {
        switch self {
        case .noText: String(localized: "There’s no readable text in this file.")
        }
    }
}

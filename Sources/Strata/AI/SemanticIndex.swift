import Accelerate
import Foundation
import NaturalLanguage
import UniformTypeIdentifiers

/// One document that matches a content search.
package nonisolated struct SemanticHit: Sendable, Hashable, Identifiable {
    package var id: URL { url }
    package let url: URL
    /// From the document's metadata or first heading, when it has one.
    package let title: String?
    /// 0…1, blended from meaning (embeddings) and wording (keywords).
    package let score: Float
    /// The best-matching passage, about one or two sentences, for display.
    package let snippet: String
    /// Words in `snippet` that match the query, for bolding.
    package let highlights: [String]
    /// 1-based page of the snippet, for PDFs.
    package let page: Int?
    package let semanticScore: Float
    package let keywordScore: Float
}

package nonisolated struct SemanticIndexProgress: Sendable {
    package enum Phase: String, Sendable { case scanning, indexing, saving, done }
    package var phase: Phase
    package var processed = 0
    package var total = 0
    /// Documents in the index so far.
    package var indexedFiles = 0
    package var current: URL?
    package var fraction: Double { total == 0 ? (phase == .done ? 1 : 0) : Double(processed) / Double(total) }
}

/// On-device semantic search over the text of documents in a few root folders (Documents, Desktop, Downloads…).
///
/// Indexing extracts text (`TextExtractor`), splits it into overlapping ~1,000-character passages and stores, per passage,
/// Float16 embeddings plus keyword statistics under `~/Library/Application Support/Strata/semantic/`. Passes are incremental
/// (path, size, modification date), notice deletions, run at utility priority with a pause between files, and stop when their
/// task is cancelled.
///
/// Search blends three on-device signals, because each alone misses things (measured on the harness corpus):
/// - the mean of `NLEmbedding.wordEmbedding` vectors of a passage's distinct words: the best topical signal ("dessert" → cake);
/// - optionally `NLEmbedding.sentenceEmbedding`: slower, adds little on top (off by default);
/// - BM25 keyword scoring: exact names, numbers and rare words that embeddings blur.
package actor SemanticIndex {
    package nonisolated struct Configuration: Sendable {
        package var roots: [URL]
        /// Whose key seals it.
        package let storage: SecureStorage.Context
        /// Made when the index is first saved, not before.
        package var storeDirectory: URL
        package var extraction = TextExtractor.Options(maxCharacters: 40_000, maxPDFPages: 20)
        package var chunkSize = 1000
        package var chunkOverlap = 160
        package var maxChunksPerFile = 24
        /// Also embed passages with the sentence model (~0.1 ms per character; about 20× slower indexing).
        package var sentenceEmbeddings = false
        /// Pause between files; longer in Low Power Mode or when the Mac is hot.
        package var throttle: Duration = .milliseconds(15)
        package var maxFiles = 40_000
        /// Skip folders that are git work trees.
        package var skipsRepositories = true
        package var excludedFolderNames: Set<String> = [
            "node_modules", ".git", "build", ".build", "DerivedData", "Pods", "Carthage", "vendor", "__pycache__", ".venv",
            "venv", "target", "dist", "Library",
        ]
        /// Results below this blended score are dropped.
        package var minimumScore: Float = 0.2

        package init(roots: [URL], storage: SecureStorage.Context) {
            self.roots = roots
            self.storage = storage
            storeDirectory = storage.directory.appending(path: "semantic", directoryHint: .isDirectory)
        }
    }

    /// The content index over ~/Documents, ~/Desktop and ~/Downloads, in the app's saved state.
    package static let shared = SemanticIndex(configuration: Configuration(roots: standardRoots, storage: .shared))

    package nonisolated static var standardRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Documents", "Desktop", "Downloads"].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    package private(set) var configuration: Configuration
    private let indexEmbedder: Embedder
    private let queryEmbedder: Embedder

    private var files: [String: IndexedFile] = [:]
    /// Passage vectors by row (Float16). Rows of deleted passages are recycled.
    private var wordRows = VectorRows(dimension: Embedder.wordDimension)
    private var sentenceRows: VectorRows
    private var rowCount = 0
    private var freeRows: [Int] = []
    private var loaded = false
    private var loading = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var updating = false
    private var unsavedChanges = 0
    private var lastSave = ContinuousClock.now

    package init(configuration: Configuration) {
        self.configuration = configuration
        // Disabled sentence embeddings keep an empty matrix, including while loading or recycling passage rows.
        sentenceRows = VectorRows(dimension: configuration.sentenceEmbeddings ? Embedder.sentenceDimension : 0)
        indexEmbedder = Embedder(label: "dev.strata.semantic.index", qos: .utility, sentences: configuration.sentenceEmbeddings)
        queryEmbedder = Embedder(label: "dev.strata.semantic.query", qos: .userInitiated, sentences: configuration.sentenceEmbeddings)
    }

    package func setRoots(_ roots: [URL]) {
        configuration.roots = roots
    }

    package var indexedFileCount: Int { files.values.filter { !$0.chunks.isEmpty }.count }

    /// Reserved vector storage, including reusable rows, for memory measurements.
    package var vectorStorageBytes: (word: Int, sentence: Int) { (wordRows.storageBytes, sentenceRows.storageBytes) }

    // MARK: - Indexing

    /// Brings the index up to date with the roots. Cancel the calling task to stop; work done so far is kept.
    package func update(progress: (@Sendable (SemanticIndexProgress) -> Void)? = nil) async throws {
        await loadIfNeeded()
        guard !updating else { return }
        updating = true
        defer { updating = false }

        progress?(SemanticIndexProgress(phase: .scanning, indexedFiles: indexedFileCount))
        let found = await Self.scan(configuration)
        try Task.checkCancellation()

        for path in files.keys where found[path] == nil {
            remove(path)
        }
        let todo = found.filter { path, stamp in
            guard let existing = files[path] else { return true }
            return existing.size != stamp.size || existing.modified != stamp.modified
        }
        // Newest first: recently touched documents are the likeliest searches.
        .sorted { $0.value.modified > $1.value.modified }

        var report = SemanticIndexProgress(phase: .indexing, total: todo.count, indexedFiles: indexedFileCount)
        do {
            for (index, (path, stamp)) in todo.enumerated() {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path)
                report.processed = index
                report.current = url
                report.indexedFiles = indexedFileCount
                progress?(report)

                let record = await Self.process(url, stamp: stamp, configuration: configuration, embedder: indexEmbedder)
                try Task.checkCancellation()
                store(record, at: path)
                if unsavedChanges >= 100 || ContinuousClock.now - lastSave > .seconds(30) { await save() }
                try await throttle()
            }
        } catch {
            // Keep what was finished, on disk too.
            await save()
            throw error
        }
        if unsavedChanges > 0 {
            progress?(SemanticIndexProgress(phase: .saving, processed: todo.count, total: todo.count, indexedFiles: indexedFileCount))
            await save()
        }
        progress?(SemanticIndexProgress(phase: .done, processed: todo.count, total: todo.count, indexedFiles: indexedFileCount))
    }

    /// Indexes or re-indexes one file now (for example right after Strata renamed or saved it), regardless of roots.
    package func refresh(_ url: URL) async {
        await loadIfNeeded()
        let path = url.standardizedFileURL.path
        guard let stamp = Self.stamp(url) else {
            remove(path)
            return
        }
        store(await Self.process(url, stamp: stamp, configuration: configuration, embedder: indexEmbedder), at: path)
    }

    /// Forgets a file (deleted or moved out of the roots).
    package func forget(_ url: URL) {
        remove(url.standardizedFileURL.path)
    }

    /// Deletes everything stored on disk and in memory.
    package func reset() {
        files = [:]
        wordRows.removeAll()
        sentenceRows.removeAll()
        rowCount = 0
        freeRows = []
        unsavedChanges = 0
        loaded = true
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func throttle() async throws {
        var delay = configuration.throttle
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { delay *= 4 }
        switch info.thermalState {
        case .serious: delay += .seconds(2)
        case .critical: delay += .seconds(10)
        default: break
        }
        try await Task.sleep(for: delay)
    }

    private func store(_ record: IndexedFile.Pending, at path: String) {
        remove(path)
        var chunks: [IndexedFile.Chunk] = []
        for chunk in record.chunks {
            let row = allocateRow()
            wordRows.set(row, chunk.word)
            sentenceRows.set(row, chunk.sentence)
            chunks.append(IndexedFile.Chunk(text: chunk.text, start: chunk.start, pages: chunk.pages, terms: chunk.terms,
                                            counts: chunk.counts, length: chunk.length, row: row))
        }
        files[path] = IndexedFile(size: record.stamp.size, modified: record.stamp.modified, title: record.title, chunks: chunks)
        unsavedChanges += 1
    }

    private func remove(_ path: String) {
        guard let file = files.removeValue(forKey: path) else { return }
        for chunk in file.chunks {
            wordRows.set(chunk.row, nil)
            sentenceRows.set(chunk.row, nil)
            freeRows.append(chunk.row)
        }
        unsavedChanges += 1
    }

    private func allocateRow() -> Int {
        if let row = freeRows.popLast() { return row }
        rowCount += 1
        wordRows.grow(to: rowCount)
        sentenceRows.grow(to: rowCount)
        return rowCount - 1
    }

    // MARK: - Search

    /// Documents whose content best matches `text`, best first.
    package func search(_ text: String, limit: Int = 20) async -> [SemanticHit] {
        await loadIfNeeded()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !files.isEmpty, limit > 0 else { return [] }
        let signals = await signals(for: query)

        var ranked: [(path: String, score: Float, semantic: Float, keyword: Float)] = []
        for candidate in signals.candidates {
            let semantic = signals.semantic(word: candidate.word, sentence: candidate.sentence)
            // Some shared words, or clearly closer in meaning than the rest of the collection.
            let relevant = candidate.keyword >= 0.12 || candidate.name > 0 || signals.isClearlyRelated(word: candidate.word)
            let score = Self.blend(semantic: semantic, keyword: candidate.keyword, nameBonus: candidate.name)
            if relevant, score >= configuration.minimumScore { ranked.append((candidate.path, score, semantic, candidate.keyword)) }
        }
        ranked.sort { $0.score > $1.score }

        var hits: [SemanticHit] = []
        for match in ranked.prefix(limit) {
            guard !match.path.isEmpty,
                  let file = files[match.path],
                  // The passage to quote: best blend of meaning and wording within this document.
                  let chunk = file.chunks.max(by: { signals.chunkScore($0) < signals.chunkScore($1) }) else { continue }
            let snippet = await Self.snippet(chunk.text, chunkStart: chunk.start, pages: chunk.pages, terms: Set(signals.terms),
                                             queryVector: signals.queryWordVector, embedder: queryEmbedder)
            hits.append(SemanticHit(url: URL(fileURLWithPath: match.path), title: file.title, score: match.score,
                                    snippet: snippet.text, highlights: snippet.highlights, page: snippet.page,
                                    semanticScore: match.semantic, keywordScore: match.keyword))
        }
        return hits
    }

    /// Diagnostics: the raw signals behind a search, per document (best passage cosines, keyword score, name overlap).
    package func explain(_ text: String) async -> [(url: URL, word: Float, sentence: Float, keyword: Float, name: Float)] {
        await loadIfNeeded()
        return await signals(for: text).candidates.compactMap {
            guard !$0.path.isEmpty else { return nil }
            return (URL(fileURLWithPath: $0.path), $0.word, $0.sentence, $0.keyword, $0.name)
        }
    }

    private func signals(for query: String) async -> QuerySignals {
        let terms = Array(Set(Terms.normalize(query)))
        let embedding = await queryEmbedder.embed([query]).first ?? PassageEmbedding()
        let wordCosines = embedding.word.map { wordRows.similarities(to: $0, rows: rowCount) } ?? []
        let sentenceCosines = embedding.sentence.map { sentenceRows.similarities(to: $0, rows: rowCount) } ?? []
        let keyword = KeywordScorer(terms: terms, files: files)
        var candidates: [QuerySignals.Candidate] = []
        for (path, file) in files where !file.chunks.isEmpty {
            let name = keyword.nameOverlap(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, title: file.title)
            candidates.append(.init(path: path, word: file.chunks.map { wordCosines[safe: $0.row] }.max() ?? 0,
                                    sentence: file.chunks.map { sentenceCosines[safe: $0.row] }.max() ?? 0,
                                    keyword: file.chunks.map(keyword.score).max() ?? 0, name: name))
        }
        return QuerySignals(terms: terms, queryWordVector: embedding.word, candidates: candidates,
                            wordCosines: wordCosines, sentenceCosines: sentenceCosines, keyword: keyword)
    }

    /// Everything computed once per query.
    private nonisolated struct QuerySignals {
        struct Candidate {
            let path: String
            let word: Float
            let sentence: Float
            let keyword: Float
            let name: Float
        }

        let terms: [String]
        let queryWordVector: [Float]?
        let candidates: [Candidate]
        let wordCosines: [Float]
        let sentenceCosines: [Float]
        let keyword: KeywordScorer
        let wordCalibration: Calibration
        let sentenceCalibration: Calibration?

        init(terms: [String], queryWordVector: [Float]?, candidates: [Candidate], wordCosines: [Float], sentenceCosines: [Float],
             keyword: KeywordScorer) {
            self.terms = terms
            self.queryWordVector = queryWordVector
            self.candidates = candidates
            self.wordCosines = wordCosines
            self.sentenceCosines = sentenceCosines
            self.keyword = keyword
            wordCalibration = Calibration(candidates.map(\.word), prior: Calibration.wordPrior, minimumSpread: Calibration.wordSpread)
            sentenceCalibration = sentenceCosines.isEmpty ? nil
                : Calibration(candidates.map(\.sentence), prior: Calibration.sentencePrior, minimumSpread: Calibration.sentenceSpread)
        }

        func semantic(word: Float, sentence: Float) -> Float {
            let fromWords = queryWordVector == nil ? nil : wordCalibration.semantic(word)
            let fromSentences = sentenceCalibration?.semantic(sentence)
            switch (fromWords, fromSentences) {
            case let (w?, s?): return 0.75 * w + 0.25 * s
            case let (w?, nil): return w
            case let (nil, s?): return s
            default: return 0
            }
        }

        func isClearlyRelated(word: Float) -> Bool {
            queryWordVector != nil && wordCalibration.isClearlyRelated(word)
        }

        func chunkScore(_ chunk: IndexedFile.Chunk) -> Float {
            SemanticIndex.blend(semantic: semantic(word: wordCosines[safe: chunk.row], sentence: sentenceCosines[safe: chunk.row]),
                                keyword: keyword.score(chunk), nameBonus: 0)
        }
    }

    /// Embedding cosines depend on the query (a short query scores low against everything), so each document is measured
    /// against the collection's typical score for this query rather than on an absolute scale.
    package nonisolated struct Calibration {
        package static let wordPrior: Float = 0.45
        package static let wordSpread: Float = 0.25
        package static let sentencePrior: Float = 0.1
        package static let sentenceSpread: Float = 0.25

        package let typical: Float
        package let spread: Float

        package init(_ cosines: [Float], prior: Float, minimumSpread: Float) {
            let sorted = cosines.sorted()
            let median = sorted.isEmpty ? prior : sorted[sorted.count / 2]
            // Small collections give a noisy median; lean on the usual unrelated level until there are enough documents.
            let weight = Float(sorted.count) / Float(sorted.count + 8)
            typical = weight * median + (1 - weight) * prior
            spread = max((sorted.last ?? 0) - typical, minimumSpread)
        }

        package func semantic(_ cosine: Float) -> Float { min(1, max(0, (cosine - typical) / spread)) }

        package func isClearlyRelated(_ cosine: Float) -> Bool { cosine - typical >= 0.6 * spread }
    }

    package nonisolated static func blend(semantic: Float, keyword: Float, nameBonus: Float) -> Float {
        min(1, 0.6 * semantic + 0.4 * keyword.squareRoot() + 0.1 * nameBonus)
    }

    // MARK: - Snippets

    /// The sentence (or two) of a passage that best matches the query, with the matching words and its PDF page.
    package nonisolated static func snippet(_ text: String, chunkStart: Int, pages: [PageMark], terms: Set<String>, queryVector: [Float]?,
                                    embedder: Embedder) async -> (text: String, highlights: [String], page: Int?) {
        let sentences = TextChunker.segments(text)
        guard !sentences.isEmpty else { return (String(text.prefix(220)), [], pages.first.map { Int($0.page) }) }
        // Each query word counts more when it is rare within the passage ("taper" beats "marathon" in a training plan).
        let stems = sentences.map { Set(Terms.normalize($0.text)) }
        var spread: [String: Int] = [:]
        for set in stems { for term in set where terms.contains(term) { spread[term, default: 0] += 1 } }
        var scores = stems.enumerated().map { index, set -> Float in
            set.intersection(terms).reduce(Float(0)) { $0 + 1 / Float(spread[$1] ?? 1) } + (sentences[index].text.count > 40 ? 0.05 : 0)
        }
        if scores.allSatisfy({ $0 < 0.5 }), let queryVector {
            // No shared words: pick by meaning instead (word vectors are cheap lookups).
            for (index, sentence) in sentences.prefix(24).enumerated() {
                if let vector = embedder.wordVector(sentence.text) {
                    scores[index] = zip(vector, queryVector).reduce(0) { $0 + $1.0 * $1.1 }
                }
            }
        }
        // Best pair of neighbouring sentences: an answer often spans two ("Viewing Saturday…" + "Bring proof of income…").
        let windowScores = scores.indices.map { scores[$0] + (scores.indices.contains($0 + 1) ? scores[$0 + 1] * 0.9 : 0) }
        let bestIndex = windowScores.indices.max { (windowScores[$0], -$0) < (windowScores[$1], -$1) } ?? 0
        var picked = sentences[bestIndex].text
        var next = bestIndex + 1
        while picked.count < 140, next < sentences.count {
            picked += "\n" + sentences[next].text
            next += 1
        }
        var snippet = trim(displayText(picked), around: terms, limit: 240)
        if bestIndex > 0 || chunkStart > 0, !snippet.hasPrefix("…") { snippet = "…" + snippet }
        let offset = sentences[bestIndex].start
        let page = pages.last(where: { Int($0.offset) <= offset }) ?? pages.first
        return (snippet, highlights(in: snippet, terms: terms), page.map { Int($0.page) })
    }

    /// Passage text as prose: Markdown markers and table pipes removed, lines joined.
    package nonisolated static func displayText(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.allSatisfy({ "|-: ".contains($0) }) { continue }  // table rule
            while line.hasPrefix("#") { line.removeFirst() }
            for marker in ["- [ ] ", "- [x] ", "* ", "- ", "> "] where line.hasPrefix(marker) { line.removeFirst(marker.count) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
            if line.hasPrefix("|") {
                line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: " ")
    }

    private nonisolated static func trim(_ text: String, around terms: Set<String>, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let firstMatch = words.firstIndex { word in Terms.normalize(String(word)).contains(where: terms.contains) } ?? 0
        var start = max(0, firstMatch - 8)
        var output = words[start...].joined(separator: " ")
        while output.count > limit, start < firstMatch {
            start += 1
            output = words[start...].joined(separator: " ")
        }
        if output.count > limit {
            output = String(output.prefix(limit))
            if let space = output.lastIndex(of: " ") { output = String(output[..<space]) }
            output += "…"
        }
        return (start > 0 ? "…" : "") + output
    }

    package nonisolated static func highlights(in text: String, terms: Set<String>) -> [String] {
        var seen: Set<String> = []
        var words: [String] = []
        for word in Terms.words(text) {
            let w = String(word)
            guard let stem = Terms.normalize(w).first, terms.contains(stem), seen.insert(w.lowercased()).inserted else { continue }
            words.append(w)
        }
        return words
    }

    // MARK: - Scanning and processing (off the actor)

    @concurrent
    private static func scan(_ configuration: Configuration) async -> [String: FileStamp] {
        scanSync(configuration)
    }

    private nonisolated static func scanSync(_ configuration: Configuration) -> [String: FileStamp] {
        var found: [String: FileStamp] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                      .contentTypeKey]
        let fm = FileManager.default
        for root in configuration.roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard found.count < configuration.maxFiles else { return found }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true, values.isPackage != true {
                    // Source repositories are code, not documents: they'd crowd out real documents under `maxFiles`.
                    if configuration.excludedFolderNames.contains(url.lastPathComponent)
                        || (configuration.skipsRepositories && fm.fileExists(atPath: url.appending(path: ".git").path)) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let isRTFD = values.isPackage == true && url.pathExtension.lowercased() == "rtfd"
                guard values.isRegularFile == true || isRTFD,
                      TextExtractor.canExtract(url, contentType: values.contentType, options: configuration.extraction),
                      let stamp = isRTFD ? stamp(url) : FileStamp(values) else { continue }
                found[url.standardizedFileURL.path] = stamp
            }
        }
        return found
    }

    package nonisolated static func stamp(_ url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isPackageKey]) else { return nil }
        if values.isPackage == true {
            // Packages (RTFD): the newest member decides, since editors may rewrite one file inside.
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let members = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
            let stamps = members.compactMap { try? $0.resourceValues(forKeys: Set(keys)) }
            let size = stamps.map { Int64($0.fileSize ?? 0) }.saturatingSum
            let modified = stamps.compactMap(\.contentModificationDate).max() ?? values.contentModificationDate
            return modified.map { FileStamp(size: size, modified: $0.timeIntervalSinceReferenceDate) }
        }
        return FileStamp(values)
    }

    @concurrent
    private static func process(_ url: URL, stamp: FileStamp, configuration: Configuration, embedder: Embedder) async -> IndexedFile.Pending {
        guard let extracted = await TextExtractor.extract(url, options: configuration.extraction) else {
            // Remember unreadable files too, so they aren't retried until they change.
            return IndexedFile.Pending(stamp: stamp, title: nil, chunks: [])
        }
        let pieces = TextChunker.chunks(extracted.text, target: configuration.chunkSize, overlap: configuration.chunkOverlap,
                                        maxChunks: configuration.maxChunksPerFile)
        // A little context in every passage: the title or file name often carries the topic ("Invoice", "Lease").
        let context = extracted.title ?? url.deletingPathExtension().lastPathComponent
        let embeddings = await embedder.embed(pieces.map { context + ". " + $0.text })
        var chunks: [IndexedFile.Pending.Chunk] = []
        for (piece, embedding) in zip(pieces, embeddings) {
            let counted = Dictionary(Terms.normalize(context + " " + piece.text).map { (Terms.hash($0), 1) }, uniquingKeysWith: +)
            let terms = counted.keys.sorted()
            var pages: [PageMark] = []
            for offset in piece.offsets {
                guard let page = extracted.page(atUTF16Offset: offset.inSource) else { break }
                if pages.last.map({ Int($0.page) != page }) ?? true { pages.append(PageMark(offset: UInt32(offset.inChunk), page: UInt32(page))) }
            }
            chunks.append(.init(text: piece.text, start: piece.start, pages: pages, terms: terms,
                                counts: terms.map { UInt8(min(255, counted[$0] ?? 1)) }, length: counted.values.reduce(0, +),
                                word: embedding.word.map(Half.encode), sentence: embedding.sentence.map(Half.encode)))
        }
        return IndexedFile.Pending(stamp: stamp, title: extracted.title, chunks: chunks)
    }

    // MARK: - Persistence

    private var storeURL: URL { configuration.storeDirectory.appending(path: "index.sealed") }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        if loading {
            await withCheckedContinuation { loadWaiters.append($0) }
            return
        }
        loading = true
        defer {
            loading = false
            loaded = true
            let waiters = loadWaiters
            loadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        // Earlier builds kept passages in a plain property list: start over rather than keep that copy around.
        SecureStorage.removeLegacy(configuration.storeDirectory.appending(path: "index.plist"))
        guard let stored = await Self.read(storeURL, storage: configuration.storage),
              stored.version == StoredIndex.currentVersion,
              stored.revision == Embedder.revision, stored.sentences == configuration.sentenceEmbeddings else { return }
        for file in stored.files {
            guard !file.path.isEmpty else { continue }
            let context = file.title ?? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
            let contextLength = context.utf16.count
            guard file.size >= 0, file.modified.isFinite,
                  file.chunks.allSatisfy({ $0.isValid(contextLength: contextLength) }) else { continue }
            if files[file.path] != nil { remove(file.path) }
            var chunks: [IndexedFile.Chunk] = []
            for chunk in file.chunks {
                let row = allocateRow()
                wordRows.set(row, chunk.word.halves())
                sentenceRows.set(row, chunk.sentence.halves())
                chunks.append(IndexedFile.Chunk(text: chunk.text, start: chunk.start, pages: PageMark.unpack(chunk.pages),
                                                terms: chunk.terms.unpacked(), counts: [UInt8](chunk.counts), length: chunk.length,
                                                row: row))
            }
            files[file.path] = IndexedFile(size: file.size, modified: file.modified, title: file.title, chunks: chunks)
        }
    }

    /// Writes the index if anything changed.
    package func save() async {
        guard unsavedChanges > 0 else { return }
        var stored = StoredIndex(sentences: configuration.sentenceEmbeddings, files: [])
        stored.files.reserveCapacity(files.count)
        for (path, file) in files {
            let chunks = file.chunks.map { chunk in
                StoredIndex.Chunk(text: chunk.text, start: chunk.start, pages: PageMark.pack(chunk.pages), terms: .packed(chunk.terms),
                                  counts: Data(chunk.counts), length: chunk.length, word: wordRows.data(chunk.row),
                                  sentence: sentenceRows.data(chunk.row))
            }
            stored.files.append(.init(path: path, size: file.size, modified: file.modified, title: file.title, chunks: chunks))
        }
        unsavedChanges = 0
        lastSave = .now
        await Self.write(stored, to: storeURL, storage: configuration.storage)
    }

    @concurrent
    private static func read(_ url: URL, storage: SecureStorage.Context) async -> StoredIndex? {
        guard let data = storage.read(url) else { return nil }
        return try? PropertyListDecoder().decode(StoredIndex.self, from: data)
    }

    @concurrent
    private static func write(_ index: StoredIndex, to url: URL, storage: SecureStorage.Context) async {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(index) else { return }
        storage.makeFolder(url.deletingLastPathComponent())
        try? storage.write(data, to: url)
    }

    /// Bytes used on disk.
    package func storeSize() -> Int64 {
        Int64((try? storeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

// MARK: - Storage types

package nonisolated struct FileStamp: Sendable, Hashable {
    package var size: Int64
    package var modified: Double

    package init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }

    package init?(_ values: URLResourceValues) {
        guard let date = values.contentModificationDate else { return nil }
        size = Int64(values.fileSize ?? 0)
        modified = date.timeIntervalSinceReferenceDate
    }
}

/// A PDF page starting at a UTF-16 offset of a passage.
package nonisolated struct PageMark: Sendable, Hashable {
    package var offset: UInt32
    package var page: UInt32

    package static func pack(_ marks: [PageMark]) -> Data {
        .packed(marks.flatMap { [$0.offset, $0.page] })
    }

    package static func unpack(_ data: Data) -> [PageMark] {
        let values = data.unpacked()
        return stride(from: 0, to: values.count - 1, by: 2).map { PageMark(offset: values[$0], page: values[$0 + 1]) }
    }
}

private nonisolated struct IndexedFile: Sendable {
    struct Chunk: Sendable {
        let text: String
        let start: Int
        /// Where PDF pages begin within `text`.
        let pages: [PageMark]
        /// Sorted term hashes, with matching counts.
        let terms: [UInt32]
        let counts: [UInt8]
        let length: Int
        let row: Int

        func count(of term: UInt32) -> Int {
            var low = 0, high = terms.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if terms[mid] == term { return Int(counts[mid]) }
                if terms[mid] < term { low = mid + 1 } else { high = mid - 1 }
            }
            return 0
        }
    }

    /// A processed file on its way into the index.
    struct Pending: Sendable {
        struct Chunk: Sendable {
            let text: String
            let start: Int
            let pages: [PageMark]
            let terms: [UInt32]
            let counts: [UInt8]
            let length: Int
            let word: [UInt16]?
            let sentence: [UInt16]?
        }

        let stamp: FileStamp
        let title: String?
        let chunks: [Chunk]
    }

    let size: Int64
    let modified: Double
    let title: String?
    let chunks: [Chunk]
}

private nonisolated struct StoredIndex: Codable, Sendable {
    static let currentVersion = 3

    struct Chunk: Codable, Sendable {
        var text: String
        var start: Int
        var pages: Data
        var terms: Data
        var counts: Data
        var length: Int
        /// Float16 bit patterns; empty when the passage had no vector.
        var word: Data
        var sentence: Data

        func isValid(contextLength: Int) -> Bool {
            let textLength = text.utf16.count
            // Keyword length includes the title or filename added by process, not just the passage text.
            let (maximumLength, overflow) = textLength.addingReportingOverflow(contextLength)
            guard !overflow, start >= 0, start <= Int.max - textLength, length >= 0, length <= maximumLength,
                  terms.count % 4 == 0, terms.count / 4 == counts.count, pages.count % 8 == 0 else { return false }
            let hashes = terms.unpacked()
            guard zip(hashes, hashes.dropFirst()).allSatisfy({ $0 < $1 }),
                  counts.allSatisfy({ $0 > 0 }), counts.reduce(0, { $0 + Int($1) }) <= length else { return false }
            let marks = PageMark.unpack(pages)
            guard marks.allSatisfy({ $0.offset <= textLength && $0.page > 0 }),
                  zip(marks, marks.dropFirst()).allSatisfy({ $0.offset <= $1.offset }) else { return false }
            func validVector(_ data: Data, dimension: Int) -> Bool {
                guard !data.isEmpty else { return true }
                guard data.count == dimension * 2 else { return false }
                return data.halves()?.allSatisfy { $0 & 0x7c00 != 0x7c00 } == true
            }
            return validVector(word, dimension: Embedder.wordDimension)
                && validVector(sentence, dimension: Embedder.sentenceDimension)
        }
    }

    struct File: Codable, Sendable {
        var path: String
        var size: Int64
        var modified: Double
        var title: String?
        var chunks: [Chunk]
    }

    var version = currentVersion
    var revision = Embedder.revision
    var sentences: Bool
    var files: [File]
}

private nonisolated extension Data {
    static func packed(_ values: [UInt32]) -> Data {
        values.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }

    func unpacked() -> [UInt32] {
        withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }

    func halves() -> [UInt16]? {
        isEmpty ? nil : withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self) }
        }
    }
}

private nonisolated extension Array where Element == Float {
    subscript(safe index: Int) -> Float { indices.contains(index) ? self[index] : 0 }
}

/// Fixed-width Float16 vectors by row, with blocked cosine similarity against a unit-length query.
private nonisolated struct VectorRows {
    let dimension: Int
    private(set) var halves: [UInt16] = []

    init(dimension: Int) { self.dimension = dimension }

    var storageBytes: Int { halves.capacity * MemoryLayout<UInt16>.stride }

    mutating func grow(to rows: Int) {
        if halves.count < rows * dimension { halves.append(contentsOf: repeatElement(0, count: rows * dimension - halves.count)) }
    }

    mutating func removeAll() { halves = [] }

    /// Stores a row; nil zeroes it (scores 0 against everything).
    mutating func set(_ row: Int, _ vector: [UInt16]?) {
        let base = row * dimension
        guard base + dimension <= halves.count else { return }
        if let vector, vector.count == dimension {
            halves.replaceSubrange(base..<base + dimension, with: vector)
        } else {
            halves.replaceSubrange(base..<base + dimension, with: repeatElement(0, count: dimension))
        }
    }

    func data(_ row: Int) -> Data {
        let base = row * dimension
        let slice = halves[base..<base + dimension]
        return slice.allSatisfy { $0 == 0 } ? Data() : slice.withUnsafeBytes { Data($0) }
    }

    func similarities(to query: [Float], rows: Int) -> [Float] {
        guard rows > 0, query.count == dimension, halves.count >= rows * dimension else { return [] }
        var result = [Float](repeating: 0, count: rows)
        let blockRows = 512
        var block = [Float](repeating: 0, count: blockRows * dimension)
        halves.withUnsafeBufferPointer { halves in
            query.withUnsafeBufferPointer { q in
                result.withUnsafeMutableBufferPointer { out in
                    var start = 0
                    while start < rows {
                        let count = min(blockRows, rows - start)
                        block.withUnsafeMutableBufferPointer { floats in
                            Half.decode(UnsafeBufferPointer(rebasing: halves[(start * dimension)..<((start + count) * dimension)]),
                                        into: floats.baseAddress!)
                            vDSP_mmul(floats.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress! + start, 1,
                                      vDSP_Length(count), 1, vDSP_Length(dimension))
                        }
                        start += count
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Keyword scoring

/// BM25 over passages, using the term hashes stored with each passage.
private nonisolated struct KeywordScorer {
    let terms: [String]
    let hashes: [UInt32]
    let idf: [Float]
    let averageLength: Float
    let maximum: Float
    private let k1: Float = 1.2
    private let b: Float = 0.75

    init(terms: [String], files: [String: IndexedFile]) {
        self.terms = terms
        hashes = terms.map(Terms.hash)
        var documentFrequency = [Int](repeating: 0, count: terms.count)
        var passages = 0
        var totalLength = 0
        for file in files.values {
            for chunk in file.chunks {
                passages += 1
                let (nextTotal, overflow) = totalLength.addingReportingOverflow(chunk.length)
                totalLength = overflow ? .max : nextTotal
                for (index, hash) in hashes.enumerated() where chunk.count(of: hash) > 0 { documentFrequency[index] += 1 }
            }
        }
        let n = Float(max(passages, 1))
        idf = documentFrequency.map { df in log(1 + (n - Float(df) + 0.5) / (Float(df) + 0.5)) }
        averageLength = Float(totalLength) / n
        maximum = idf.reduce(0, +) * (k1 + 1)
    }

    /// 0…1: the share of the best possible score (every query word, repeated often).
    func score(_ chunk: IndexedFile.Chunk) -> Float {
        guard maximum > 0 else { return 0 }
        var total: Float = 0
        let norm = k1 * (1 - b + b * Float(chunk.length) / max(averageLength, 1))
        for (index, hash) in hashes.enumerated() {
            let tf = Float(chunk.count(of: hash))
            guard tf > 0 else { continue }
            total += idf[index] * tf * (k1 + 1) / (tf + norm)
        }
        return total / maximum
    }

    /// Share of query words found in the file name or title.
    func nameOverlap(_ name: String, title: String?) -> Float {
        guard !terms.isEmpty else { return 0 }
        let stems = Set(Terms.normalize(name + " " + (title ?? "")))
        return Float(terms.filter(stems.contains).count) / Float(terms.count)
    }
}

// MARK: - Embedding

package nonisolated struct PassageEmbedding: Sendable {
    package var word: [Float]?
    package var sentence: [Float]?
}

/// On-device embeddings on a private serial queue (NLEmbedding isn't thread-safe), returned unit-length:
/// the mean of word vectors over a passage's distinct content words, and optionally a sentence embedding.
package nonisolated final class Embedder: @unchecked Sendable {
    package static let wordDimension = 300
    package static let sentenceDimension = 512
    package static let language = NLLanguage.english
    package static var revision: Int {
        NLEmbedding.currentRevision(for: language) * 1000 + NLEmbedding.currentSentenceEmbeddingRevision(for: language)
    }

    /// Whether on-device word embeddings exist for the index language (they ship with macOS).
    package static var isAvailable: Bool { NLEmbedding.wordEmbedding(for: language) != nil }

    private let queue: DispatchQueue
    private let sentences: Bool
    private let lock = NSLock()
    private var words: NLEmbedding?
    private var sentenceModel: NLEmbedding?
    private var didLoad = false

    package init(label: String, qos: DispatchQoS, sentences: Bool) {
        queue = DispatchQueue(label: label, qos: qos)
        self.sentences = sentences
    }

    package func embed(_ texts: [String]) async -> [PassageEmbedding] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: texts.map { text in
                    PassageEmbedding(word: self.wordVector(text), sentence: self.sentences ? self.sentenceVector(text) : nil)
                })
            }
        }
    }

    /// Mean word vector of the distinct content words; nil when none are in the vocabulary. Cheap (table lookups).
    package func wordVector(_ text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let words else { return nil }
        var seen: Set<Substring> = []
        var sum = [Double](repeating: 0, count: Self.wordDimension)
        var found = 0
        for word in Terms.words(text.lowercased()) where word.count >= 3 && word.allSatisfy(\.isLetter) {
            guard !Terms.stopwords.contains(String(word)), seen.insert(word).inserted, seen.count <= 400,
                  let vector = words.vector(for: String(word)), vector.count == Self.wordDimension else { continue }
            for index in 0..<Self.wordDimension { sum[index] += vector[index] }
            found += 1
        }
        guard found > 0 else { return nil }
        return Self.unit(sum.map(Float.init))
    }

    private func sentenceVector(_ text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let sentenceModel, let raw = sentenceModel.vector(for: text), raw.count == Self.sentenceDimension else { return nil }
        return Self.unit(raw.map(Float.init))
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        words = NLEmbedding.wordEmbedding(for: Self.language)
        if sentences { sentenceModel = NLEmbedding.sentenceEmbedding(for: Self.language) }
    }

    private static func unit(_ vector: [Float]) -> [Float]? {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        var result = vector
        vDSP_vsdiv(vector, 1, &norm, &result, 1, vDSP_Length(vector.count))
        return result
    }
}

/// Float ⇄ IEEE half conversion via vImage (works on every architecture, unlike `Float16`).
package nonisolated enum Half {
    package static func encode(_ floats: [Float]) -> [UInt16] {
        guard !floats.isEmpty else { return [] }
        var halves = [UInt16](repeating: 0, count: floats.count)
        floats.withUnsafeBufferPointer { source in
            halves.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                                        width: vImagePixelCount(floats.count), rowBytes: floats.count * 4)
                var dst = vImage_Buffer(data: destination.baseAddress!, height: 1, width: vImagePixelCount(floats.count),
                                        rowBytes: floats.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
        return halves
    }

    package static func decode(_ halves: UnsafeBufferPointer<UInt16>, into floats: UnsafeMutablePointer<Float>) {
        guard let base = halves.baseAddress, !halves.isEmpty else { return }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: 1, width: vImagePixelCount(halves.count),
                                rowBytes: halves.count * 2)
        var dst = vImage_Buffer(data: floats, height: 1, width: vImagePixelCount(halves.count), rowBytes: halves.count * 4)
        vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
    }
}

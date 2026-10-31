import AppKit

extension PaletteItem {
    /// Search results as palette rows ("Content" matches, snippet as subtitle).
    static func contentMatches(_ hits: [SemanticHit], open: @escaping (URL) -> Void) -> [PaletteItem] {
        hits.map { hit in
            var subtitle = hit.snippet
            if let page = hit.page {
                subtitle = String(localized: "p. \(page) · \(hit.snippet)",
                                  comment: "Content search result: the PDF page the matching text is on, then the text")
            }
            let score = hit.score.isFinite ? Int((min(max(hit.score, 0), 100) * 100).rounded()) : 0
            return PaletteItem(title: hit.title ?? hit.url.lastPathComponent, subtitle: subtitle,
                               icon: IconCache.shared.icon(forPath: hit.url.path, folder: false), kind: .match,
                               fixedScore: score) { open(hit.url) }
        }
    }
}

import Foundation

/// One page of a section behind the offline WebKit boundary: its markup, and each picture read from the section only
/// when WebKit asks for it, re-encoded within the page's budgets.
package actor OneNotePageDocument {
    /// What a page may show and hand WebKit. A real notebook's busiest page holds 59 pictures, 53 million pixels and
    /// 8.4 MB of them re-encoded, and a page of pasted phone photos a dozen of 12 million pixels and 5 MB each: the
    /// defaults leave room above both, and still bound one page.
    package struct Budget: Sendable {
        package var pictures = 63
        /// A picture's own bytes, as the section holds them.
        package var pictureBytes = PreviewPicture.byteLimit
        package var pixels = 160_000_000
        /// What its pictures come to, re-encoded.
        package var bytes = 24 << 20
        package init() {}
    }

    nonisolated package let url: URL
    /// What WebKit may ask this page for: the page and its pictures, and their bytes as the page's budget allows.
    nonisolated package let limits: HTMLWebSession.Limits
    private let section: OneNoteSectionFile
    private let page: HTMLPreviewResource
    private let pictures: [OneNoteData]
    private let pictureBytes: Int
    private var cache: [Int: HTMLPreviewResource] = [:]
    /// Pictures that couldn't be made: asked for again, they're refused without being paid for again.
    private var refused: Set<Int> = []
    private var remainingBytes: Int
    private var remainingPixels: Int

    package init(section: OneNoteSectionFile, page: OneNotePage, budget: Budget = .init()) async throws {
        let markup = try await section.markup(of: page, pictureLimit: budget.pictures,
                                              pictureBytes: budget.pictureBytes)
        self.section = section
        self.page = HTMLPreviewResource(data: Data(markup.html.utf8), mime: "text/html; charset=utf-8")
        pictures = markup.pictures
        // WebKit may ask for the page and each picture it names twice, as when it stops a load and starts it again.
        limits = HTMLWebSession.Limits(requests: 2 * (markup.pictures.count + 1),
                                       bytes: 2 * (self.page.data.count + budget.bytes))
        pictureBytes = budget.pictureBytes
        remainingBytes = budget.bytes
        remainingPixels = budget.pixels
        url = URL(string: "\(HTMLPreviewDocument.scheme)://\(UUID().uuidString.lowercased())/page.html")!
    }

    package func read(_ request: URL) async throws -> HTMLPreviewResource {
        try Task.checkCancellation()
        let parts = try HTMLPreviewDocument.components(request, origin: url)
        if parts == ["page.html"] { return page }
        guard parts.count == 2, parts[0] == "pictures", let index = Int(parts[1]), String(index) == parts[1],
              pictures.indices.contains(index) else { throw PreviewError.unsupported }
        if let cached = cache[index] { return cached }
        guard !refused.contains(index) else { throw PreviewError.unsupported }
        let data = try await section.bytes(of: pictures[index], limit: pictureBytes)
        try Task.checkCancellation()
        // Another request may have made it meanwhile, or found it couldn't be, and paid for it.
        if let cached = cache[index] { return cached }
        guard !refused.contains(index) else { throw PreviewError.unsupported }
        do {
            let resource = try HTMLPreviewResource.picture(data, pixels: &remainingPixels, bytes: &remainingBytes)
            cache[index] = resource
            return resource
        } catch {
            refused.insert(index)
            throw error
        }
    }
}

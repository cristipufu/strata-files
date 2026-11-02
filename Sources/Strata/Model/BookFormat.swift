import Foundation

/// Comic aliases stay archives. EPUB packages supply a reading order and a declared cover instead.
nonisolated package enum BookFormat {
    package static let comics: Set<String> = ["cbz", "cbr", "cb7", "cbt"]
    package static func hasCover(_ url: URL) -> Bool {
        comics.contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "epub"
    }
    package static let images: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic", "heif", "tif", "tiff", "bmp"]
}

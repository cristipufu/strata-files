import AVFoundation
import Foundation
import StrataSupport

nonisolated package struct MediaLocation: Equatable, Sendable {
    package let latitude: Double
    package let longitude: Double

    package init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude; self.longitude = longitude
    }

    package var coordinates: String { String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude) }
    package var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "ll", value: coordinates)]
        return components?.url
    }
}

nonisolated package struct MediaChapter: Equatable, Sendable {
    package let start: Double
    package let title: String

    package init?(start: Double, title: String) {
        guard start.isFinite, start >= 0, title.utf8.count <= MediaNavigation.titleByteLimit else { return nil }
        self.start = start; self.title = DisplayText.oneLine(title)
    }
}

nonisolated package struct MediaNavigation: Equatable, Sendable {
    package static let chapterLimit = 512
    package static let trackLimit = 128
    package static let titleByteLimit = 1024
    package let chapters: [MediaChapter]?
    package let subtitles: [String]?

    package init(chapters: [MediaChapter]? = nil, subtitles: [String]? = nil) {
        self.chapters = chapters.flatMap { values in
            guard values.count <= Self.chapterLimit,
                  zip(values, values.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { return nil }
            return values
        }
        self.subtitles = subtitles.flatMap { values in
            guard values.count <= Self.trackLimit, values.allSatisfy({ $0.utf8.count <= Self.titleByteLimit }) else { return nil }
            return values.map(DisplayText.oneLine)
        }
    }

    @concurrent package static func read(_ asset: AVURLAsset) async -> Self {
        async let chapters = readChapters(asset)
        async let subtitles = readSubtitles(asset)
        return await Self(chapters: chapters, subtitles: subtitles)
    }

    private static func readChapters(_ asset: AVURLAsset) async -> [MediaChapter]? {
        guard !Task.isCancelled,
              let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages),
              groups.count <= chapterLimit else { return nil }
        var chapters: [MediaChapter] = []
        for group in groups {
            guard !Task.isCancelled, group.items.count <= trackLimit else { return nil }
            let items = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle)
            let title = if let item = items.first { (try? await item.load(.stringValue)) ?? "" } else { "" }
            guard let chapter = MediaChapter(start: group.timeRange.start.seconds, title: title),
                  chapters.last.map({ $0.start <= chapter.start }) ?? true else { return nil }
            chapters.append(chapter)
        }
        return chapters
    }

    private static func readSubtitles(_ asset: AVURLAsset) async -> [String]? {
        guard !Task.isCancelled else { return nil }
        do {
            guard let group = try await asset.loadMediaSelectionGroup(for: .legible) else { return [] }
            guard group.options.count <= trackLimit else { return nil }
            var result: [String] = []
            for option in group.options {
                guard !Task.isCancelled else { return nil }
                let name = option.displayName
                guard name.utf8.count <= titleByteLimit else { return nil }
                result.append(DisplayText.oneLine(name))
            }
            return result
        } catch { return nil }
    }
}

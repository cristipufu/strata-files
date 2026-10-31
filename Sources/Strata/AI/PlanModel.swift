import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A selected file and everything a plan may refer to.
package nonisolated struct PlanItem: Sendable, Hashable, Identifiable {
    package var id: URL { url }
    package let url: URL
    package let name: String
    package let isFolder: Bool
    package let kind: String
    package let contentType: UTType?
    package let size: Int64?
    package let created: Date?
    package let modified: Date?
    /// EXIF DateTimeOriginal (with its offset when present), for photos.
    package let captureDate: Date?
    package let cameraModel: String?

    /// Name without the extension (folders keep their whole name).
    package var baseName: String { isFolder || ext.isEmpty ? name : (name as NSString).deletingPathExtension }
    package var ext: String { isFolder ? "" : (name as NSString).pathExtension }

    /// When the content came to be: the capture date, else the earlier of created and modified (copies reset "created").
    package var bestDate: Date? { captureDate ?? [created, modified].compactMap { $0 }.min() }

    package func date(_ source: PlanRecipe.DateSource) -> Date? {
        switch source {
        case .taken: captureDate
        case .created: created
        case .modified: modified
        case .best: bestDate
        }
    }

    package init(url: URL, name: String, isFolder: Bool, kind: String, contentType: UTType?, size: Int64?, created: Date?, modified: Date?,
         captureDate: Date?, cameraModel: String?) {
        self.url = url.standardizedFileURL
        self.name = name
        self.isFolder = isFolder
        self.kind = kind
        self.contentType = contentType
        self.size = size
        self.created = created
        self.modified = modified
        self.captureDate = captureDate
        self.cameraModel = cameraModel
    }

    /// Reads metadata (and EXIF for images) off the main thread.
    @concurrent
    package static func load(_ urls: [URL]) async -> [PlanItem] {
        urls.compactMap { url in
            guard let entry = FileEntry(url: url) else { return nil }
            var capture: (Date?, String?) = (nil, nil)
            if entry.contentType?.conforms(to: .image) == true { capture = exif(url) }
            return PlanItem(url: url, name: entry.name, isFolder: entry.isFolder, kind: entry.kind, contentType: entry.contentType,
                            size: entry.size, created: entry.created, modified: entry.modified, captureDate: capture.0,
                            cameraModel: capture.1)
        }
    }

    /// Date taken and camera model from the image header (no pixel decoding).
    package static func exif(_ url: URL) -> (Date?, String?) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return (nil, nil) }
        var info = stat()
        let isRegular = fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        close(fd)
        guard isRegular,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any] else { return (nil, nil) }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]) as? String else {
            return (nil, model)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String, let zone = TimeZone(iso8601Offset: offset) {
            formatter.timeZone = zone
        } else {
            formatter.timeZone = .current
        }
        return (formatter.date(from: raw), model?.isEmpty == false ? model : nil)
    }
}

private nonisolated extension TimeZone {
    /// "+02:00" / "-0530".
    init?(iso8601Offset text: String) {
        let digits = text.filter(\.isNumber)
        guard let sign = text.first, sign == "+" || sign == "-", digits.count == 4, let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)) else { return nil }
        self.init(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}

/// An operation as proposed by the model or expanded from a recipe, before validation.
package nonisolated enum ProposedOperation: Sendable, Hashable {
    case rename(URL, to: String)
    /// Folder: relative to the plan's base folder, or `~/…` / an absolute path.
    case move(URL, into: String)
    case createFolder(String)
    case trash(URL)
}

/// One validated, reviewable change.
package nonisolated struct PlanStep: Sendable, Hashable, Identifiable {
    package enum Kind: String, Sendable {
        case rename, move, createFolder, trash

        /// For VoiceOver and other spoken or written descriptions.
        package var title: String {
            switch self {
            case .rename: String(localized: "Rename", comment: "Kind of plan step, read by VoiceOver: rename an item")
            case .move: String(localized: "Move", comment: "Kind of plan step, read by VoiceOver: move an item")
            case .createFolder: String(localized: "New folder", comment: "Kind of plan step, read by VoiceOver: create a folder")
            case .trash: String(localized: "Move to Trash", comment: "Kind of plan step, read by VoiceOver: move an item to the Trash")
            }
        }
    }

    package let id: Int
    package let kind: Kind
    /// The selected item (nil for a new folder).
    package let source: URL?
    /// Where it ends up (nil for Trash).
    package let destination: URL?
    package var isEnabled = true
    /// Why the step was excluded; nil for valid steps.
    package var problem: String?
    /// A small adjustment made during validation ("Kept the .jpg extension").
    package var note: String?

    package var beforeName: String { source?.lastPathComponent ?? destination?.lastPathComponent ?? "" }
}

/// A reviewable plan: valid steps (applied when checked) and steps that were excluded, with reasons.
package nonisolated struct Plan: Sendable {
    package enum Source: String, Sendable {
        case rules = "Built-in rules"
        case model = "Apple Intelligence"

        /// For the review sheet's badge.
        package var title: String {
            switch self {
            case .rules: String(localized: "Built-in rules", comment: "Badge: the plan was made by Strata’s rules, not by AI")
            case .model: "Apple Intelligence"
            }
        }
    }

    package var instruction: String
    package var source: Source
    /// What the instruction was understood as ("Rename by date taken").
    package var interpretation: String
    package var baseFolder: URL
    package var steps: [PlanStep]
    package var excluded: [PlanStep]
    /// Selected items the plan leaves alone (not matched, or already as asked).
    package var unaffected: Int

    package var enabledSteps: [PlanStep] { steps.filter(\.isEnabled) }

    /// "4 renames · 2 moves · 1 new folder".
    package var summary: String {
        let enabled = enabledSteps
        func count(_ kind: PlanStep.Kind) -> Int { enabled.filter { $0.kind == kind }.count }
        var parts: [String] = []
        if count(.rename) > 0 { parts.append(String(localized: "\(count(.rename)) renames", comment: "plural; noun: how many items a plan renames")) }
        if count(.move) > 0 { parts.append(String(localized: "\(count(.move)) moves", comment: "plural; noun: how many items a plan moves")) }
        if count(.createFolder) > 0 { parts.append(String(localized: "\(count(.createFolder)) new folders", comment: "plural")) }
        if count(.trash) > 0 { parts.append(String(localized: "\(count(.trash)) to Trash", comment: "plural; how many items a plan moves to the Trash")) }
        if parts.isEmpty { parts.append(String(localized: "No changes")) }
        if !excluded.isEmpty { parts.append(String(localized: "\(excluded.count) skipped", comment: "plural; how many steps of a plan were left out")) }
        return parts.joined(separator: " · ")
    }

    /// Steps that change an item (not folder creation).
    package var changeCount: Int { enabledSteps.filter { $0.kind != .createFolder }.count }
}

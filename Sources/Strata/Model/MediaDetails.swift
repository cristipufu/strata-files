import AVFoundation
import CNativeReaders
import CoreMedia
import Foundation
import StrataSupport
import UniformTypeIdentifiers

nonisolated package struct MediaDetails: Equatable, Sendable {
    package typealias Reader = @concurrent @Sendable (URL, UTType?) async -> MediaDetails

    nonisolated package struct Photo: Equatable, Sendable {
        package let taken: Date?
        package let camera: String?
        package let lens: String?
        package let exposure: Double?
        package let aperture: Double?
        package let iso: Double?
        package let focalLength: Double?
        package let focalLength35mm: Double?
        package let location: MediaLocation?
        package let colorProfile: String?
        package let frameCount: Int?
        package let caption: String?
        package let keywords: [String]

        package init(taken: Date? = nil, camera: String? = nil, lens: String? = nil,
                     exposure: Double? = nil, aperture: Double? = nil, iso: Double? = nil,
                     focalLength: Double? = nil, focalLength35mm: Double? = nil, location: MediaLocation? = nil,
                     colorProfile: String? = nil, frameCount: Int? = nil, caption: String? = nil,
                     keywords: [String] = []) {
            self.taken = taken; self.camera = camera; self.lens = lens
            self.exposure = exposure; self.aperture = aperture; self.iso = iso
            self.focalLength = focalLength; self.focalLength35mm = focalLength35mm; self.location = location
            self.colorProfile = colorProfile; self.frameCount = frameCount
            self.caption = caption; self.keywords = keywords
        }
    }

    nonisolated package struct Video: Equatable, Sendable {
        package let codec: String?
        package let frameRate: Double?
        package let bitRate: Double?
        package var isHDR: Bool? = nil
    }

    nonisolated package struct Audio: Equatable, Sendable {
        package let codec: String?
        package let channels: Int?
        package let bitRate: Double?
        package let sampleRate: Double?
        package let title: String?
        package let artist: String?
        package let album: String?
        package let year: String?

        package init(codec: String? = nil, channels: Int? = nil, bitRate: Double? = nil,
                     sampleRate: Double? = nil, title: String? = nil, artist: String? = nil,
                     album: String? = nil, year: String? = nil) {
            self.codec = codec; self.channels = channels; self.bitRate = bitRate
            self.sampleRate = sampleRate; self.title = title; self.artist = artist
            self.album = album; self.year = year
        }
    }

    nonisolated package struct Book: Equatable, Sendable {
        package let title: String?
        package let author: String?
        package let series: String?
        package let pages: Int?
        package let isChapters: Bool

        package init(title: String? = nil, author: String? = nil, series: String? = nil,
                     pages: Int? = nil, isChapters: Bool = false) {
            self.title = title; self.author = author; self.series = series
            self.pages = pages; self.isChapters = isChapters
        }
    }

    nonisolated package struct Spreadsheet: Equatable, Sendable {
        package let sheets: [String]
        package init(sheets: [String]) { self.sheets = sheets }
    }

    nonisolated package struct Database: Equatable, Sendable {
        package let tables: [String]
        package let rowCount: Int64?
        package let columnCount: Int?

        package init(tables: [String] = [], rowCount: Int64? = nil, columnCount: Int? = nil) {
            self.tables = tables; self.rowCount = rowCount; self.columnCount = columnCount
        }
    }

    nonisolated package struct Design: Equatable, Sendable {
        package let pageCount: Int?
        package let artboardCount: Int?
        package let artboards: [String]

        package init(pageCount: Int? = nil, artboardCount: Int? = nil, artboards: [String] = []) {
            self.pageCount = pageCount
            self.artboardCount = artboardCount
            self.artboards = artboards
        }
    }

    package let basic: MediaInfo
    package let photo: Photo?
    package let video: Video?
    package let audio: Audio?
    package let navigation: MediaNavigation
    package var book: Book?
    package var spreadsheet: Spreadsheet?
    package var database: Database?
    package var font: FontMetadata.Face?
    package var design: Design?
    package var track: GeoTrackMetadata.Track?
    package var certificate: CertificateMetadata.Summary?
    package var app: AppBundleMetadata.Summary?
    package var model: MLHeaderMetadata.Summary?

    package var coordinates: MediaLocation? {
        photo?.location ?? track?.startLocation
    }

    package init(basic: MediaInfo = MediaInfo(), photo: Photo? = nil, video: Video? = nil, audio: Audio? = nil,
                 navigation: MediaNavigation = MediaNavigation(), book: Book? = nil,
                 spreadsheet: Spreadsheet? = nil, database: Database? = nil, font: FontMetadata.Face? = nil,
                 design: Design? = nil, track: GeoTrackMetadata.Track? = nil,
                 certificate: CertificateMetadata.Summary? = nil, app: AppBundleMetadata.Summary? = nil,
                 model: MLHeaderMetadata.Summary? = nil) {
        self.basic = basic; self.photo = photo; self.video = video; self.audio = audio
        self.navigation = navigation; self.book = book; self.spreadsheet = spreadsheet
        self.database = database; self.font = font; self.design = design
        self.track = track; self.certificate = certificate; self.app = app; self.model = model
    }

    @concurrent package static func read(_ url: URL, contentType: UTType?) async -> Self {
        guard !Task.isCancelled, url.isFileURL, !DatalessFile.isDataless(url.path) else { return Self() }
        let ext = url.pathExtension.lowercased()
        if ext == "app" {
            let result = await OwnThread.run { Self(app: AppBundleMetadata.read(url)) }
            return Task.isCancelled ? Self() : result
        }
        if FontMetadata.extensions.contains(ext) {
            let result = await OwnThread.run { Self(font: FontMetadata.read(url).first) }
            return Task.isCancelled ? Self() : result
        }
        if GeoTrackMetadata.extensions.contains(ext) {
            let result = await OwnThread.run { Self(track: GeoTrackMetadata.read(url)) }
            return Task.isCancelled ? Self() : result
        }
        if CertificateMetadata.extensions.contains(ext) {
            let result = await OwnThread.run { Self(certificate: CertificateMetadata.read(url)) }
            return Task.isCancelled ? Self() : result
        }
        if ext == "parquet" {
            let result = await OwnThread.run {
                guard let summary = ParquetMetadata.read(url) else { return Self() }
                return Self(database: Database(rowCount: summary.rowCount, columnCount: summary.columns.count))
            }
            return Task.isCancelled ? Self() : result
        }
        if MLHeaderMetadata.extensions.contains(ext) {
            let result = await OwnThread.run { Self(model: MLHeaderMetadata.read(url)) }
            return Task.isCancelled ? Self() : result
        }
        if contentType?.conforms(to: .image) == true {
            let result = await OwnThread.run { image(url) }
            return Task.isCancelled ? Self() : result
        }
        guard contentType?.conforms(to: .audiovisualContent) == true,
              await OwnThread.run({ MediaInfo.isRegularFile(url) }), !Task.isCancelled else { return Self() }
        let asset = AVURLAsset(url: url)
        return await withTaskCancellationHandler {
            async let basic = MediaInfo.readAsset(asset)
            async let video = videoTrack(asset)
            async let audio = audioTrack(asset)
            async let navigation = MediaNavigation.read(asset)
            let result = await Self(basic: basic, video: video, audio: audio, navigation: navigation)
            return Task.isCancelled ? Self() : result
        } onCancel: { asset.cancelLoading() }
    }

    private static func image(_ url: URL) -> Self {
        guard let metadata = DatalessFile.withoutMaterializing({ try? STImageReader.metadata(at: url) }),
              !Task.isCancelled else { return Self() }
        let make = cleaned(metadata.cameraMake), model = cleaned(metadata.cameraModel)
        let camera: String?
        if let make, let model, !model.lowercased().hasPrefix(make.lowercased()) { camera = make + " " + model }
        else { camera = model ?? make }
        let location: MediaLocation?
        if let latitude = metadata.latitude?.doubleValue, let longitude = metadata.longitude?.doubleValue {
            location = MediaLocation(latitude: latitude, longitude: longitude)
        } else { location = nil }
        let frames = metadata.frameCount > 1 ? metadata.frameCount : nil
        let keywords = (metadata.keywords ?? []).compactMap(cleaned)
        return Self(basic: MediaInfo(imageMetadata: metadata), photo: Photo(
            taken: dateTaken(metadata.captureDate, offset: metadata.captureOffset), camera: camera,
            lens: cleaned(metadata.lensModel), exposure: positive(metadata.exposureTime?.doubleValue),
            aperture: positive(metadata.aperture?.doubleValue), iso: positive(metadata.iso?.doubleValue),
            focalLength: positive(metadata.focalLength?.doubleValue),
            focalLength35mm: positive(metadata.focalLength35mm?.doubleValue), location: location,
            colorProfile: cleaned(metadata.profileName), frameCount: frames,
            caption: cleaned(metadata.caption), keywords: keywords))
    }

    private static func videoTrack(_ asset: AVURLAsset) async -> Video? {
        guard !Task.isCancelled, let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let codec = await codec(track, kind: kCMMediaType_Video)
        guard !Task.isCancelled else { return nil }
        let rate = try? await track.load(.nominalFrameRate)
        guard !Task.isCancelled else { return nil }
        let bits = try? await track.load(.estimatedDataRate)
        return Video(codec: codec, frameRate: positive(rate.map(Double.init)), bitRate: positive(bits.map(Double.init)),
                     isHDR: codec == nil ? nil : track.hasMediaCharacteristic(.containsHDRVideo))
    }

    private static func audioTrack(_ asset: AVURLAsset) async -> Audio? {
        guard !Task.isCancelled, let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let description = try? await track.load(.formatDescriptions).first
        guard !Task.isCancelled else { return nil }
        var name: String?, channels: Int?, pcmBitRate: Double?, sampleRate: Double?
        if let description, CFGetTypeID(description) == CMFormatDescriptionGetTypeID(),
           CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio {
            name = codecName(CMFormatDescriptionGetMediaSubType(description))
            if let format = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                sampleRate = positive(format.pointee.mSampleRate)
                if (1...256).contains(format.pointee.mChannelsPerFrame) {
                    channels = Int(format.pointee.mChannelsPerFrame)
                    if format.pointee.mFormatID == kAudioFormatLinearPCM {
                        pcmBitRate = positive(format.pointee.mSampleRate * Double(format.pointee.mBytesPerFrame) * 8)
                    }
                }
            }
        }
        let bits = try? await track.load(.estimatedDataRate)
        let tags = await readTags(asset)
        return Audio(codec: name, channels: channels, bitRate: positive(bits.map(Double.init)) ?? pcmBitRate,
                     sampleRate: sampleRate, title: tags.title, artist: tags.artist, album: tags.album, year: tags.year)
    }

    private static func readTags(_ asset: AVURLAsset) async -> (title: String?, artist: String?, album: String?, year: String?) {
        guard !Task.isCancelled, let items = try? await asset.load(.commonMetadata), !items.isEmpty else {
            return (nil, nil, nil, nil)
        }
        func firstString(_ id: AVMetadataIdentifier) async -> String? {
            guard !Task.isCancelled,
                  let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                  let value = try? await item.load(.stringValue) else { return nil }
            return cleaned(value)
        }
        let title = await firstString(.commonIdentifierTitle)
        let artist = await firstString(.commonIdentifierArtist)
        let album = await firstString(.commonIdentifierAlbumName)
        let rawDate = await firstString(.commonIdentifierCreationDate)
        let year: String? = rawDate.flatMap { str in
            let prefix = String(str.prefix(4))
            if prefix.count == 4, let y = Int(prefix), (1900...2100).contains(y) { return prefix }
            return nil
        }
        return (title, artist, album, year)
    }

    private static func codec(_ track: AVAssetTrack, kind: CMMediaType) async -> String? {
        guard !Task.isCancelled, let description = try? await track.load(.formatDescriptions).first,
              CFGetTypeID(description) == CMFormatDescriptionGetTypeID(),
              CMFormatDescriptionGetMediaType(description) == kind else { return nil }
        return codecName(CMFormatDescriptionGetMediaSubType(description))
    }

    package static func codecName(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(format: "0x%08X", code) }
        let raw = String(decoding: bytes, as: UTF8.self)
        return ["avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1", "vp09": "VP9",
                "jpeg": "JPEG", "lpcm": "PCM", "mp4a": "AAC", "alac": "ALAC", ".mp3": "MP3",
                "apch": "Apple ProRes 422 HQ", "apcn": "Apple ProRes 422", "apcs": "Apple ProRes 422 LT",
                "apco": "Apple ProRes 422 Proxy", "ap4h": "Apple ProRes 4444", "ap4x": "Apple ProRes 4444 XQ"][raw] ?? raw
    }

    package static func dateTaken(_ raw: String?, offset: String?) -> Date? {
        guard let raw, raw.utf8.count <= 64 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        formatter.timeZone = zone(offset) ?? .current
        return formatter.date(from: raw)
    }

    private static func zone(_ offset: String?) -> TimeZone? {
        guard let offset, [5, 6].contains(offset.utf8.count) else { return nil }
        var bytes = Array(offset.utf8)
        let sign = bytes.removeFirst()
        guard sign == 43 || sign == 45 else { return nil }
        if bytes.count == 5 {
            guard bytes[2] == 58 else { return nil }
            bytes.remove(at: 2)
        }
        guard bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let hours = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48)
        let minutes = Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
        guard hours <= 23, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: (sign == 45 ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    private static func positive(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let result = String(text.unicodeScalars.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

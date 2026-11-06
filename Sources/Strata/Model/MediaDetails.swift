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

        package init(taken: Date? = nil, camera: String? = nil, lens: String? = nil,
                     exposure: Double? = nil, aperture: Double? = nil, iso: Double? = nil,
                     focalLength: Double? = nil, focalLength35mm: Double? = nil, location: MediaLocation? = nil) {
            self.taken = taken; self.camera = camera; self.lens = lens
            self.exposure = exposure; self.aperture = aperture; self.iso = iso
            self.focalLength = focalLength; self.focalLength35mm = focalLength35mm; self.location = location
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
    }

    package let basic: MediaInfo
    package let photo: Photo?
    package let video: Video?
    package let audio: Audio?
    package let navigation: MediaNavigation

    package init(basic: MediaInfo = MediaInfo(), photo: Photo? = nil, video: Video? = nil, audio: Audio? = nil,
                 navigation: MediaNavigation = MediaNavigation()) {
        self.basic = basic; self.photo = photo; self.video = video; self.audio = audio
        self.navigation = navigation
    }

    @concurrent package static func read(_ url: URL, contentType: UTType?) async -> Self {
        guard !Task.isCancelled, url.isFileURL else { return Self() }
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
        guard let metadata = try? STImageReader.metadata(at: url), !Task.isCancelled else { return Self() }
        let make = cleaned(metadata.cameraMake), model = cleaned(metadata.cameraModel)
        let camera: String?
        if let make, let model, !model.lowercased().hasPrefix(make.lowercased()) { camera = make + " " + model }
        else { camera = model ?? make }
        let location: MediaLocation?
        if let latitude = metadata.latitude?.doubleValue, let longitude = metadata.longitude?.doubleValue {
            location = MediaLocation(latitude: latitude, longitude: longitude)
        } else { location = nil }
        return Self(basic: MediaInfo(imageMetadata: metadata), photo: Photo(
            taken: dateTaken(metadata.captureDate, offset: metadata.captureOffset), camera: camera,
            lens: cleaned(metadata.lensModel), exposure: positive(metadata.exposureTime?.doubleValue),
            aperture: positive(metadata.aperture?.doubleValue), iso: positive(metadata.iso?.doubleValue),
            focalLength: positive(metadata.focalLength?.doubleValue), focalLength35mm: positive(metadata.focalLength35mm?.doubleValue), location: location))
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
        var name: String?, channels: Int?, pcmBitRate: Double?
        if let description, CFGetTypeID(description) == CMFormatDescriptionGetTypeID(),
           CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio {
            name = codecName(CMFormatDescriptionGetMediaSubType(description))
            if let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
               (1...256).contains(format.pointee.mChannelsPerFrame) {
                channels = Int(format.pointee.mChannelsPerFrame)
                if format.pointee.mFormatID == kAudioFormatLinearPCM {
                    pcmBitRate = positive(format.pointee.mSampleRate * Double(format.pointee.mBytesPerFrame) * 8)
                }
            }
        }
        let bits = try? await track.load(.estimatedDataRate)
        return Audio(codec: name, channels: channels, bitRate: positive(bits.map(Double.init)) ?? pcmBitRate)
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

import Foundation
import StrataModel
import StrataSupport

@MainActor enum MediaDetailRows {
    static func rows(_ details: MediaDetails) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let photo = details.photo { rows += photoRows(photo) }
        if let duration = details.basic.durationText { rows.append((String(localized: "Duration"), duration)) }
        if let video = details.video {
            if let codec = video.codec { rows.append((String(localized: "Video codec"), codec)) }
            if let isHDR = video.isHDR { rows.append((String(localized: "Dynamic range"), isHDR ? "HDR" : "SDR")) }
            if let rate = positive(video.frameRate) {
                rows.append((String(localized: "Frame rate"), String(localized: "\(number(rate)) fps", comment: "Media frame rate in frames per second")))
            }
        }
        if let rate = positive(details.video?.bitRate ?? details.audio?.bitRate) {
            rows.append((String(localized: "Bit rate"), bitRate(rate)))
        }
        if let audio = details.audio {
            if let codec = audio.codec { rows.append((String(localized: "Audio format"), codec)) }
            if let channels = audio.channels, (1...256).contains(channels) {
                rows.append((String(localized: "Channels"), channels.formatted()))
            }
        }
        if let chapters = details.navigation.chapters, !chapters.isEmpty {
            rows.append((String(localized: "Chapters"), chapters.count.formatted()))
        }
        if let subtitles = details.navigation.subtitles, !subtitles.isEmpty {
            let names = subtitles.prefix(3).joined(separator: ", ") + (subtitles.count > 3 ? ", …" : "")
            rows.append((String(localized: "Subtitles"), subtitles.count.formatted() + " · " + names))
        }
        return rows
    }

    private static func photoRows(_ photo: MediaDetails.Photo) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let date = photo.taken { rows.append((String(localized: "Date taken"), Format.longDate(date))) }
        if let camera = photo.camera { rows.append((String(localized: "Camera"), camera)) }
        if let lens = photo.lens { rows.append((String(localized: "Lens"), lens)) }
        if let length = positive(photo.focalLength) { rows.append((String(localized: "Focal length"), number(length) + " mm")) }
        if let length = positive(photo.focalLength35mm) { rows.append((String(localized: "35 mm equivalent"), number(length) + " mm")) }
        if let seconds = positive(photo.exposure) {
            let reciprocal = 1 / seconds
            let denominator = reciprocal.rounded()
            let fraction = seconds < 1 && reciprocal.isFinite && abs(reciprocal - denominator) <= reciprocal * 0.001
            let text = fraction ? "1/" + number(denominator, decimals: 0) : number(seconds, decimals: 6)
            rows.append((String(localized: "Exposure"), text + " s"))
        }
        if let aperture = positive(photo.aperture) { rows.append((String(localized: "Aperture"), "ƒ/" + number(aperture))) }
        if let iso = positive(photo.iso) { rows.append((String(localized: "ISO", comment: "Camera sensitivity; standard ISO designation"), number(iso, decimals: 0))) }
        return rows
    }

    private static func positive(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }

    private static func number(_ value: Double, decimals: Int = 3) -> String {
        if value >= 1_000_000_000 || value < 0.0001 {
            return value.formatted(.number.notation(.scientific).precision(.fractionLength(0...decimals)))
        }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...decimals)))
    }

    private static func bitRate(_ bits: Double) -> String {
        if bits >= 1_000_000 { return number(bits / 1_000_000, decimals: 2) + " Mbit/s" }
        if bits >= 1000 { return number(bits / 1000, decimals: 1) + " kbit/s" }
        return number(bits) + " bit/s"
    }
}

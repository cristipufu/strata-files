import Foundation
import StrataModel
import StrataSupport

@MainActor enum MediaDetailRows {
    static func rows(_ details: MediaDetails) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let photo = details.photo { rows += photoRows(photo) }
        if let audio = details.audio { rows += audioTagRows(audio) }
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
            if let sampleRate = positive(audio.sampleRate) {
                rows.append((String(localized: "Sample rate"), sampleRateText(sampleRate)))
            }
            if let channels = audio.channels, (1...256).contains(channels) {
                rows.append((String(localized: "Channels"), channels.formatted()))
            }
        }
        if let chapters = details.navigation.chapters, !chapters.isEmpty {
            rows.append((String(localized: "Chapters"), chapters.count.formatted()))
        }
        if let subtitles = details.navigation.subtitles, !subtitles.isEmpty {
            rows.append((String(localized: "Subtitles"), summarizedList(subtitles)))
        }
        if let book = details.book { rows += bookRows(book) }
        if let spreadsheet = details.spreadsheet { rows += spreadsheetRows(spreadsheet) }
        if let database = details.database { rows += databaseRows(database) }
        if let font = details.font { rows += fontRows(font) }
        if let design = details.design { rows += designRows(design) }
        if let track = details.track { rows += trackRows(track) }
        if let certificate = details.certificate { rows += certificateRows(certificate) }
        if let app = details.app { rows += appRows(app) }
        if let model = details.model { rows += modelRows(model) }
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
        if let profile = photo.colorProfile { rows.append((String(localized: "Color profile"), profile)) }
        if let frames = photo.frameCount, frames > 1 { rows.append((String(localized: "Frames"), frames.formatted())) }
        return rows
    }

    private static func audioTagRows(_ audio: MediaDetails.Audio) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let title = audio.title { rows.append((String(localized: "Title"), title)) }
        if let artist = audio.artist { rows.append((String(localized: "Artist"), artist)) }
        if let album = audio.album { rows.append((String(localized: "Album"), album)) }
        if let year = audio.year { rows.append((String(localized: "Year"), year)) }
        return rows
    }

    private static func bookRows(_ book: MediaDetails.Book) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let title = book.title { rows.append((String(localized: "Title"), title)) }
        if let author = book.author { rows.append((String(localized: "Author"), author)) }
        if let series = book.series { rows.append((String(localized: "Series"), series)) }
        if let pages = book.pages, pages > 0 {
            let label = book.isChapters ? String(localized: "Chapters") : String(localized: "Pages")
            rows.append((label, pages.formatted()))
        }
        return rows
    }

    private static func spreadsheetRows(_ spreadsheet: MediaDetails.Spreadsheet) -> [(String, String)] {
        guard !spreadsheet.sheets.isEmpty else { return [] }
        return [(String(localized: "Sheets"), summarizedList(spreadsheet.sheets))]
    }

    private static func databaseRows(_ database: MediaDetails.Database) -> [(String, String)] {
        var rows: [(String, String)] = []
        if !database.tables.isEmpty {
            rows.append((String(localized: "Tables"), summarizedList(database.tables)))
        }
        if let rowCount = database.rowCount, rowCount >= 0 {
            rows.append((String(localized: "Rows"), rowCount.formatted()))
        }
        if let colCount = database.columnCount, colCount > 0 {
            rows.append((String(localized: "Columns"), colCount.formatted()))
        }
        return rows
    }

    private static func fontRows(_ font: FontMetadata.Face) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append((String(localized: "Family"), font.family))
        if let style = font.style { rows.append((String(localized: "Style"), style)) }
        if let version = font.version { rows.append((String(localized: "Version"), version)) }
        if let glyphs = font.glyphCount, glyphs > 0 { rows.append((String(localized: "Glyphs"), glyphs.formatted())) }
        return rows
    }

    private static func designRows(_ design: MediaDetails.Design) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let pages = design.pageCount, pages > 0 {
            rows.append((String(localized: "Pages"), pages.formatted()))
        }
        if !design.artboards.isEmpty {
            let count = design.artboardCount ?? design.artboards.count
            let preview = design.artboards.prefix(3).joined(separator: ", ") + (design.artboards.count > 3 ? ", …" : "")
            rows.append((String(localized: "Artboards"), count.formatted() + " · " + preview))
        } else if let artboards = design.artboardCount, artboards > 0 {
            rows.append((String(localized: "Artboards"), artboards.formatted()))
        }
        return rows
    }

    private static func trackRows(_ track: GeoTrackMetadata.Track) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let name = track.name { rows.append((String(localized: "Route"), name)) }
        if let meters = positive(track.distanceMeters) {
            let text = meters >= 1000 ? number(meters / 1000, decimals: 2) + " km" : number(meters, decimals: 0) + " m"
            rows.append((String(localized: "Distance"), text))
        }
        if let gain = positive(track.elevationGainMeters) {
            rows.append((String(localized: "Elevation gain"), "+" + number(gain, decimals: 0) + " m"))
        }
        return rows
    }

    private static func certificateRows(_ cert: CertificateMetadata.Summary) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let subject = cert.subject { rows.append((String(localized: "Issued to"), subject)) }
        if let issuer = cert.issuer { rows.append((String(localized: "Issued by"), issuer)) }
        if let team = cert.team { rows.append((String(localized: "Team"), team)) }
        if let appID = cert.appID { rows.append((String(localized: "App ID"), appID)) }
        if let expires = cert.expires {
            let dateText = Format.longDate(expires)
            let value = cert.isExpired ? String(localized: "\(dateText) (Expired)") : dateText
            rows.append((String(localized: "Expires"), value))
        }
        if !cert.domains.isEmpty {
            rows.append((String(localized: "Domains"), summarizedList(cert.domains)))
        }
        return rows
    }

    private static func appRows(_ app: AppBundleMetadata.Summary) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let version = app.version { rows.append((String(localized: "Version"), version)) }
        if let arch = app.architecture {
            let label = switch arch {
            case .appleSilicon: String(localized: "Apple Silicon")
            case .universal: String(localized: "Universal")
            case .intel: String(localized: "Intel")
            }
            rows.append((String(localized: "Architecture"), label))
        }
        if let minOS = app.minimumSystemVersion { rows.append((String(localized: "Minimum macOS"), minOS)) }
        if let signedBy = app.signedBy { rows.append((String(localized: "Signed by"), signedBy)) }
        return rows
    }

    private static func modelRows(_ model: MLHeaderMetadata.Summary) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let name = model.modelName { rows.append((String(localized: "Model"), name)) }
        if let arch = model.architecture { rows.append((String(localized: "Architecture"), arch)) }
        if let params = model.totalParameters, params > 0 {
            rows.append((String(localized: "Parameters"), parameterCountText(params)))
        }
        if let precision = model.precision { rows.append((String(localized: "Precision"), precision)) }
        if let shape = model.shapeDescription { rows.append((String(localized: "Shape"), shape)) }
        return rows
    }

    private static func summarizedList(_ items: [String], maxShown: Int = 3) -> String {
        let preview = items.prefix(maxShown).joined(separator: ", ") + (items.count > maxShown ? ", …" : "")
        return items.count.formatted() + " · " + preview
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

    private static func sampleRateText(_ hz: Double) -> String {
        if hz >= 1000 {
            return number(hz / 1000, decimals: 1) + " kHz"
        }
        return number(hz, decimals: 0) + " Hz"
    }

    private static func parameterCountText(_ count: Int64) -> String {
        let value = Double(count)
        if value >= 1_000_000_000 { return number(value / 1_000_000_000, decimals: 2) + "B" }
        if value >= 1_000_000 { return number(value / 1_000_000, decimals: 1) + "M" }
        if value >= 1_000 { return number(value / 1_000, decimals: 1) + "K" }
        return count.formatted()
    }
}

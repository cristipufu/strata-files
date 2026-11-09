import CNativeReaders
import Compression
import Foundation
import Security
import StrataSupport

// MARK: - XML Helper

/// A small, bounds-checked XML tree parser with entity declarations and external DTDs refused.
nonisolated package final class SafeXML: NSObject, XMLParserDelegate {
    package final class Element {
        package let name: String
        package let attributes: [String: String]
        private let namespacedAttributes: [String: [String: String]]
        package var text = ""
        package var children: [Element] = []
        package var allText: String { text }

        init(_ name: String, _ attributes: [String: String], namespaced: [String: [String: String]]) {
            self.name = name
            self.attributes = attributes
            self.namespacedAttributes = namespaced
        }

        package func attribute(_ name: String, namespace: String) -> String? {
            namespacedAttributes[namespace]?[name]
        }

        package func descendants(_ name: String) -> [Element] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
        }
    }

    package struct ParseFailure: Error {
        package init() {}
    }

    private var stack: [Element] = []
    private var root: Element?
    private var count = 0
    private var textBytes = 0
    private var prefixes: [String: [String]] = [:]
    private let maxElements: Int
    private let maxTextBytes: Int

    private init(maxElements: Int, maxTextBytes: Int) {
        self.maxElements = maxElements
        self.maxTextBytes = maxTextBytes
    }

    package static func parse(_ data: Data, maxElements: Int = 20_000, maxInputBytes: Int = TextFile.limit) throws -> Element {
        try Task.checkCancellation()
        guard data.count <= maxInputBytes, let text = String(data: data, encoding: .utf8),
              hasAllowedXMLEncoding(text),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw ParseFailure() }
        let delegate = SafeXML(maxElements: maxElements, maxTextBytes: maxInputBytes)
        let parser = XMLParser(data: Data(try withoutDocumentType(text).utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard (try? STXMLReader.parse(parser)) != nil, delegate.stack.isEmpty, let root = delegate.root else {
            throw ParseFailure()
        }
        return root
    }

    private static func withoutDocumentType(_ text: String) throws -> String {
        guard let start = text.range(of: "<!DOCTYPE", options: .caseInsensitive) else { return text }
        var cursor = start.upperBound, quote: Character?, count = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            count += character.utf8.count
            guard count <= 4096 else { throw ParseFailure() }
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                throw ParseFailure()
            } else if character == ">" {
                let end = text.index(after: cursor)
                let result = String(text[..<start.lowerBound]) + text[end...]
                guard !result.localizedCaseInsensitiveContains("<!DOCTYPE") else { throw ParseFailure() }
                return result
            }
            cursor = text.index(after: cursor)
        }
        throw ParseFailure()
    }

    package func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 64, count < maxElements, attributes.count <= 32 else { parser.abortParsing(); return }
        count += 1
        let element = Element(name, attributes, namespaced: expanded(attributes))
        if let parent = stack.last { parent.children.append(element) } else { root = element }
        stack.append(element)
    }

    private func expanded(_ attributes: [String: String]) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (name, value) in attributes {
            let parts = name.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let namespace = prefixes[String(parts[0])]?.last else { continue }
            result[namespace, default: [:]][String(parts[1])] = value
        }
        return result
    }

    package func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
        guard prefixes.count < 128, (prefixes[prefix]?.count ?? 0) < 64,
              prefix.utf8.count <= 256, uri.utf8.count <= 4096 else {
            parser.abortParsing(); return
        }
        prefixes[prefix, default: []].append(uri)
    }

    package func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        _ = prefixes[prefix]?.popLast()
        if prefixes[prefix]?.isEmpty == true { prefixes[prefix] = nil }
    }

    package func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBytes += string.utf8.count
        guard textBytes <= maxTextBytes else { parser.abortParsing(); return }
        stack.last?.text += string
    }

    package func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let string = String(data: data, encoding: .utf8) else { parser.abortParsing(); return }
        self.parser(parser, foundCharacters: string)
    }

    package func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if let child = stack.popLast() { stack.last?.text += child.text }
    }
}

// MARK: - Fonts (.ttf, .otf, .ttc, .woff)

nonisolated package enum FontMetadata {
    package static let extensions: Set<String> = ["ttf", "otf", "ttc", "woff"]
    package static let byteLimit = 16 * 1024 * 1024

    package struct Face: Equatable, Sendable {
        package let family: String
        package let fullName: String?
        package let style: String?
        package let postScriptName: String?
        package let version: String?
        package let copyright: String?
        package let glyphCount: Int?
    }

    package static func read(_ url: URL) -> [Face] {
        guard let (data, truncated) = try? TextFile.readPrefix(url, limit: byteLimit),
              !truncated, !data.isEmpty else { return [] }
        return read(data)
    }

    package static func read(_ data: Data) -> [Face] {
        guard data.count >= 12, data.count <= byteLimit, let magic = u32(data, 0) else { return [] }
        if magic == 0x74746366 { // "ttcf"
            guard let numFonts = u32(data, 8), numFonts > 0 else { return [] }
            let count = min(Int(numFonts), 32)
            var faces: [Face] = []
            for i in 0..<count {
                guard let offset = u32(data, 12 + i * 4),
                      let face = parseSfntFace(data, directoryOffset: Int(offset)) else { continue }
                faces.append(face)
            }
            return faces
        } else if magic == 0x774F4646 { // "wOFF"
            if let face = parseWoffFace(data) { return [face] }
            return []
        } else if [0x0001_0000, 0x4F54_544F, 0x7472_7565, 0x7479_7031].contains(magic) {
            if let face = parseSfntFace(data, directoryOffset: 0) { return [face] }
            return []
        }
        return []
    }

    private static func parseSfntFace(_ data: Data, directoryOffset: Int) -> Face? {
        guard directoryOffset >= 0, directoryOffset + 12 <= data.count,
              let numTables = u16(data, directoryOffset + 4),
              numTables > 0, numTables <= 128 else { return nil }
        var nameSlice: Data?
        var maxpSlice: Data?
        for i in 0..<Int(numTables) {
            let rec = directoryOffset + 12 + i * 16
            guard rec + 16 <= data.count,
                  let tag = u32(data, rec),
                  let tOffsetU = u32(data, rec + 8),
                  let tLengthU = u32(data, rec + 12) else { break }
            let tOffset = Int(tOffsetU), tLength = Int(tLengthU)
            guard tOffset >= 0, tLength > 0, tLength <= data.count, tOffset <= data.count - tLength else { continue }
            if tag == 0x6E61_6D65 { // "name"
                let capped = min(tLength, 512 * 1024)
                nameSlice = data.subdata(in: (data.startIndex + tOffset)..<(data.startIndex + tOffset + capped))
            } else if tag == 0x6D61_7870 { // "maxp"
                let capped = min(tLength, 64)
                maxpSlice = data.subdata(in: (data.startIndex + tOffset)..<(data.startIndex + tOffset + capped))
            }
        }
        guard let nameSlice else { return nil }
        return buildFace(nameTable: nameSlice, maxpTable: maxpSlice)
    }

    private static func parseWoffFace(_ data: Data) -> Face? {
        guard data.count >= 44,
              let numTables = u16(data, 12),
              numTables > 0, numTables <= 128 else { return nil }
        var nameSlice: Data?
        var maxpSlice: Data?
        for i in 0..<Int(numTables) {
            let rec = 44 + i * 20
            guard rec + 20 <= data.count,
                  let tag = u32(data, rec),
                  tag == 0x6E61_6D65 || tag == 0x6D61_7870,
                  let offsetU = u32(data, rec + 4),
                  let compLenU = u32(data, rec + 8),
                  let origLenU = u32(data, rec + 12) else { continue }
            let offset = Int(offsetU), compLen = Int(compLenU), origLen = Int(origLenU)
            guard offset >= 0, compLen > 0, origLen > 0, origLen <= 512 * 1024,
                  compLen <= data.count, offset <= data.count - compLen else { continue }
            let raw = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + compLen))
            let decoded: Data?
            if compLen == origLen {
                decoded = raw
            } else if compLen > 2 {
                // Bounded decompression into an exact origLen buffer so a WOFF zip-bomb cannot over-allocate.
                let payload = raw.subdata(in: (raw.startIndex + 2)..<raw.endIndex)
                var out = Data(count: origLen)
                let written = out.withUnsafeMutableBytes { dstPtr -> Int in
                    payload.withUnsafeBytes { srcPtr -> Int in
                        guard let dstBase = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                        return compression_decode_buffer(dstBase, origLen, srcBase, payload.count, nil, COMPRESSION_ZLIB)
                    }
                }
                decoded = written == origLen ? out : nil
            } else {
                decoded = nil
            }
            if tag == 0x6E61_6D65 { nameSlice = decoded }
            else if tag == 0x6D61_7870 { maxpSlice = decoded }
        }
        guard let nameSlice else { return nil }
        return buildFace(nameTable: nameSlice, maxpTable: maxpSlice)
    }

    private static func buildFace(nameTable: Data, maxpTable: Data?) -> Face? {
        guard nameTable.count >= 6,
              let count = u16(nameTable, 2),
              let stringOffset = u16(nameTable, 4) else { return nil }
        let n = min(Int(count), 512)
        let storageBase = Int(stringOffset)
        var best: [UInt16: (score: Int, value: String)] = [:]

        for i in 0..<n {
            let rec = 6 + i * 12
            guard rec + 12 <= nameTable.count,
                  let platformID = u16(nameTable, rec),
                  let encodingID = u16(nameTable, rec + 2),
                  let languageID = u16(nameTable, rec + 4),
                  let nameID = u16(nameTable, rec + 6),
                  [0, 1, 2, 4, 5, 6, 16, 17].contains(nameID),
                  let lengthU = u16(nameTable, rec + 8),
                  let offsetU = u16(nameTable, rec + 10) else { continue }
            let length = Int(lengthU), offset = Int(offsetU)
            guard length > 0, length <= 1024, length <= nameTable.count,
                  storageBase + offset >= 0,
                  storageBase + offset <= nameTable.count - length else { continue }
            let slice = nameTable.subdata(in: (nameTable.startIndex + storageBase + offset)..<(nameTable.startIndex + storageBase + offset + length))
            let decoded: (score: Int, text: String?) = switch (platformID, encodingID) {
            case (3, 1), (3, 10):
                (languageID == 0x0409 ? 4 : 2, String(data: slice, encoding: .utf16BigEndian))
            case (0, _):
                (languageID == 0 ? 3 : 2, String(data: slice, encoding: .utf16BigEndian))
            case (1, 0):
                (languageID == 0 ? 2 : 1, String(data: slice, encoding: .macOSRoman))
            default:
                (0, nil)
            }
            guard decoded.score > (best[nameID]?.score ?? 0),
                  let rawText = decoded.text?.replacingOccurrences(of: "\0", with: ""),
                  let value = cleaned(rawText) else { continue }
            best[nameID] = (decoded.score, value)
        }

        let rawFamily = best[16]?.value ?? best[1]?.value
        guard var family = rawFamily else { return nil }
        if family.hasPrefix("."), family.count > 1 {
            family = String(family.dropFirst())
        }
        var fullName = best[4]?.value
        if let f = fullName, f.hasPrefix("."), f.count > 1 {
            fullName = String(f.dropFirst())
        }
        let style = best[17]?.value ?? best[2]?.value
        let postScript = best[6]?.value
        var version = best[5]?.value
        if let v = version {
            if v.lowercased().hasPrefix("version ") {
                version = cleaned(String(v.dropFirst(8)))
            }
            if let semi = version?.firstIndex(of: ";") {
                version = cleaned(String(version![..<semi]))
            }
        }
        let copyright = best[0]?.value
        let glyphs: Int? = if let maxpTable, maxpTable.count >= 6, let g = u16(maxpTable, 4), g > 0 {
            Int(g)
        } else {
            nil
        }

        return Face(
            family: family,
            fullName: fullName != family ? fullName : nil,
            style: style,
            postScriptName: postScript,
            version: version,
            copyright: copyright,
            glyphCount: glyphs
        )
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    package static func cleanedName(_ text: String?) -> String? {
        cleaned(text)
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = DisplayText.oneLine(String(text.unicodeScalars.prefix(256)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Geo Tracks (.gpx, .kml, .geojson)

nonisolated package enum GeoTrackMetadata {
    package static let extensions: Set<String> = ["gpx", "kml", "geojson"]
    package static let byteLimit = 4 * 1024 * 1024
    package static let pointLimit = 50_000

    package struct Point: Equatable, Sendable {
        package let latitude: Double
        package let longitude: Double
        package let elevation: Double?

        package init?(latitude: Double, longitude: Double, elevation: Double? = nil) {
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            self.latitude = latitude
            self.longitude = longitude
            if let elevation, elevation.isFinite, (-12_000...100_000).contains(elevation) {
                self.elevation = elevation
            } else {
                self.elevation = nil
            }
        }
    }

    package struct Track: Equatable, Sendable {
        package let name: String?
        package let points: [Point]
        package let distanceMeters: Double?
        package let elevationGainMeters: Double?
        package var startLocation: MediaLocation? {
            points.first.flatMap { MediaLocation(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    package static func read(_ url: URL) -> Track? {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext),
              let (data, _) = try? TextFile.readPrefix(url, limit: byteLimit),
              !data.isEmpty else { return nil }
        return read(data, format: ext)
    }

    package static func read(_ data: Data, format: String) -> Track? {
        guard !data.isEmpty, data.count <= byteLimit else { return nil }
        let parsed: (name: String?, points: [Point])? = switch format.lowercased() {
        case "gpx": parseGPX(data)
        case "kml": parseKML(data)
        case "geojson": parseGeoJSON(data)
        default: nil
        }
        guard let parsed, !parsed.points.isEmpty else { return nil }
        let (distance, gain) = summarize(parsed.points)
        return Track(name: parsed.name, points: parsed.points, distanceMeters: distance, elevationGainMeters: gain)
    }

    private static func summarize(_ points: [Point]) -> (distance: Double?, gain: Double?) {
        guard points.count >= 2 else { return (nil, nil) }
        var totalMeters = 0.0
        var totalGain = 0.0
        var hasElevation = false
        var lastElevation: Double?
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let step = haversineMeters(a, b)
            if step.isFinite, step > 0 { totalMeters += step }
            if let ele = b.elevation {
                if let prev = lastElevation ?? a.elevation {
                    hasElevation = true
                    let delta = ele - prev
                    if delta > 0.5 {
                        totalGain += delta
                        lastElevation = ele
                    } else if delta < -0.5 {
                        lastElevation = ele
                    }
                } else {
                    lastElevation = ele
                }
            }
        }
        return (
            totalMeters >= 1 ? totalMeters : nil,
            hasElevation && totalGain >= 1 ? totalGain : nil
        )
    }

    private static func haversineMeters(_ a: Point, _ b: Point) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinLat = sin(dLat / 2)
        let sinLon = sin(dLon / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        let c = 2 * atan2(sqrt(max(0, min(1, h))), sqrt(max(0, 1 - min(1, h))))
        return radius * c
    }

    private static func parseGPX(_ data: Data) -> (name: String?, points: [Point])? {
        let delegate = GPXStreamDelegate()
        guard delegate.parse(data), !delegate.points.isEmpty else { return nil }
        return (delegate.name, delegate.points)
    }

    private static func parseKML(_ data: Data) -> (name: String?, points: [Point])? {
        let delegate = KMLStreamDelegate()
        guard delegate.parse(data), !delegate.points.isEmpty else { return nil }
        return (delegate.name, delegate.points)
    }

    private static func parseGeoJSON(_ data: Data) -> (name: String?, points: [Point])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var name: String?
        var points: [Point] = []
        collectGeoJSON(object, depth: 0, name: &name, points: &points)
        guard !points.isEmpty else { return nil }
        return (name, points)
    }

    private static func collectGeoJSON(_ dict: [String: Any], depth: Int, name: inout String?, points: inout [Point]) {
        guard depth <= 12, points.count < pointLimit else { return }
        if name == nil, let props = dict["properties"] as? [String: Any] {
            if let candidate = (props["name"] as? String) ?? (props["title"] as? String) {
                let cleaned = DisplayText.oneLine(String(candidate.unicodeScalars.prefix(256)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { name = cleaned }
            }
        }
        guard let type = dict["type"] as? String else { return }
        switch type {
        case "FeatureCollection":
            if name == nil, let title = dict["name"] as? String {
                let cleaned = DisplayText.oneLine(String(title.unicodeScalars.prefix(256)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { name = cleaned }
            }
            if let features = dict["features"] as? [[String: Any]] {
                for feature in features.prefix(10_000) {
                    collectGeoJSON(feature, depth: depth + 1, name: &name, points: &points)
                    if points.count >= pointLimit { break }
                }
            }
        case "Feature":
            if let geometry = dict["geometry"] as? [String: Any] {
                collectGeoJSON(geometry, depth: depth + 1, name: &name, points: &points)
            }
        case "GeometryCollection":
            if let geometries = dict["geometries"] as? [[String: Any]] {
                for geometry in geometries.prefix(10_000) {
                    collectGeoJSON(geometry, depth: depth + 1, name: &name, points: &points)
                    if points.count >= pointLimit { break }
                }
            }
        default:
            if let coords = dict["coordinates"] {
                collectCoordinates(coords, depth: 0, points: &points)
            }
        }
    }

    private static func collectCoordinates(_ raw: Any, depth: Int, points: inout [Point]) {
        guard depth <= 8, points.count < pointLimit, let array = raw as? [Any], !array.isEmpty else { return }
        if let lon = number(array[0]), array.count >= 2, let lat = number(array[1]) {
            let ele = array.count >= 3 ? number(array[2]) : nil
            if let point = Point(latitude: lat, longitude: lon, elevation: ele) {
                points.append(point)
            }
            return
        }
        for child in array {
            collectCoordinates(child, depth: depth + 1, points: &points)
            if points.count >= pointLimit { break }
        }
    }

    private static func number(_ value: Any) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let num = value as? NSNumber { return num.doubleValue }
        return nil
    }
}

nonisolated private final class GPXStreamDelegate: NSObject, XMLParserDelegate {
    var name: String?
    var points: [GeoTrackMetadata.Point] = []
    private var stack: [String] = []
    private var text = ""
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var pendingEle: Double?
    private var elementCount = 0

    func parse(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8),
              hasAllowedXMLEncoding(str),
              !str.localizedCaseInsensitiveContains("<!ENTITY"),
              !str.localizedCaseInsensitiveContains("<!DOCTYPE") else { return false }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = self
        return (try? STXMLReader.parse(parser)) != nil || !points.isEmpty
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        elementCount += 1
        guard stack.count < 32, elementCount <= 250_000, points.count < GeoTrackMetadata.pointLimit else {
            parser.abortParsing(); return
        }
        stack.append(local)
        text = ""
        if ["trkpt", "rtept", "wpt"].contains(local) {
            pendingLat = attributeDict["lat"].flatMap(Double.init)
            pendingLon = attributeDict["lon"].flatMap(Double.init)
            pendingEle = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.utf8.count < 1024 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        defer { _ = stack.popLast(); text = "" }
        if local == "ele", stack.count >= 2 {
            pendingEle = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if ["trkpt", "rtept", "wpt"].contains(local) {
            if let lat = pendingLat, let lon = pendingLon,
               let point = GeoTrackMetadata.Point(latitude: lat, longitude: lon, elevation: pendingEle) {
                points.append(point)
            }
            pendingLat = nil; pendingLon = nil; pendingEle = nil
        } else if local == "name", name == nil,
                  stack.dropLast().last.map({ ["trk", "rte", "metadata", "gpx"].contains($0) }) == true {
            let cleaned = DisplayText.oneLine(String(text.unicodeScalars.prefix(256)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { name = cleaned }
        }
    }
}

nonisolated private final class KMLStreamDelegate: NSObject, XMLParserDelegate {
    var name: String?
    var points: [GeoTrackMetadata.Point] = []
    private var stack: [String] = []
    private var text = ""
    private var elementCount = 0

    func parse(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8),
              hasAllowedXMLEncoding(str),
              !str.localizedCaseInsensitiveContains("<!ENTITY"),
              !str.localizedCaseInsensitiveContains("<!DOCTYPE") else { return false }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = self
        return (try? STXMLReader.parse(parser)) != nil || !points.isEmpty
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        elementCount += 1
        guard stack.count < 32, elementCount <= 100_000, points.count < GeoTrackMetadata.pointLimit else {
            parser.abortParsing(); return
        }
        stack.append(local)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.utf8.count < 512 * 1024 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        defer { _ = stack.popLast(); text = "" }
        if local == "name", name == nil,
           stack.dropLast().last.map({ ["document", "placemark", "folder"].contains($0) }) == true {
            let cleaned = DisplayText.oneLine(String(text.unicodeScalars.prefix(256)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { name = cleaned }
        } else if local == "coordinates" {
            for tuple in text.split(whereSeparator: \.isWhitespace) {
                guard points.count < GeoTrackMetadata.pointLimit else { break }
                let parts = tuple.split(separator: ",")
                guard parts.count >= 2,
                      let lon = Double(parts[0]),
                      let lat = Double(parts[1]) else { continue }
                let ele = parts.count >= 3 ? Double(parts[2]) : nil
                if let point = GeoTrackMetadata.Point(latitude: lat, longitude: lon, elevation: ele) {
                    points.append(point)
                }
            }
        } else if local == "coord" {
            // gx:coord "lon lat ele"
            let parts = text.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) {
                let ele = parts.count >= 3 ? Double(parts[2]) : nil
                if let point = GeoTrackMetadata.Point(latitude: lat, longitude: lon, elevation: ele) {
                    points.append(point)
                }
            }
        }
    }
}

// MARK: - Certificates & Provisioning Profiles (.cer, .crt, .der, .pem, .mobileprovision)

nonisolated package enum CertificateMetadata {
    package static let extensions: Set<String> = ["cer", "crt", "der", "pem", "mobileprovision", "provisionprofile"]
    package static let byteLimit = 1024 * 1024

    package struct Summary: Equatable, Sendable {
        package let isProvisioningProfile: Bool
        package let subject: String?
        package let organization: String?
        package let issuer: String?
        package let validFrom: Date?
        package let expires: Date?
        package let isExpired: Bool
        package let domains: [String]
        package let team: String?
        package let appID: String?
        package let uuid: String?
        package let platforms: [String]
        package let provisionedDeviceCount: Int?
    }

    package static func read(_ url: URL, now: Date = .now) -> Summary? {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext),
              let (data, truncated) = try? TextFile.readPrefix(url, limit: byteLimit),
              !truncated, !data.isEmpty else { return nil }
        return read(data, fileExtension: ext, now: now)
    }

    package static func read(_ data: Data, fileExtension ext: String = "", now: Date = .now) -> Summary? {
        guard !data.isEmpty, data.count <= byteLimit else { return nil }
        if ext == "mobileprovision" || ext == "provisionprofile" {
            return parseProvisioningProfile(data, now: now)
        }
        let der = extractDER(from: data) ?? data
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return parseProvisioningProfile(data, now: now)
        }
        let fallbackSubject = (SecCertificateCopySubjectSummary(cert) as String?).flatMap(cleaned)
        let parsed = parseX509DER(der)
        let subject = parsed?.subjectCN ?? fallbackSubject ?? parsed?.subjectOrg
        let issuer = parsed?.issuerCN ?? parsed?.issuerOrg
        guard subject != nil || issuer != nil else { return nil }
        let expires = parsed?.notAfter
        return Summary(
            isProvisioningProfile: false,
            subject: subject,
            organization: parsed?.subjectOrg,
            issuer: issuer,
            validFrom: parsed?.notBefore,
            expires: expires,
            isExpired: expires.map { $0 < now } ?? false,
            domains: parsed?.dnsNames ?? [],
            team: nil,
            appID: nil,
            uuid: nil,
            platforms: [],
            provisionedDeviceCount: nil
        )
    }

    private static func parseProvisioningProfile(_ data: Data, now: Date) -> Summary? {
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = data.range(of: startMarker),
              let end = data.range(of: endMarker, in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let prologStart = max(data.startIndex, start.lowerBound - 8192)
        let prologAndPlist = data.subdata(in: prologStart..<end.upperBound)
        guard plistData.count <= 512 * 1024,
              isSafePropertyListData(prologAndPlist),
              isSafePropertyListData(plistData),
              let dict = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any] else {
            return nil
        }
        let name = cleaned(dict["Name"] as? String)
        let team = cleaned(dict["TeamName"] as? String)
            ?? (dict["TeamIdentifier"] as? [String])?.first.flatMap(cleaned)
        let entitlements = dict["Entitlements"] as? [String: Any]
        let appID = cleaned(entitlements?["application-identifier"] as? String)
            ?? cleaned(entitlements?["com.apple.application-identifier"] as? String)
            ?? cleaned(dict["AppIDName"] as? String)
        let created = dict["CreationDate"] as? Date
        let expires = dict["ExpirationDate"] as? Date
        let uuid = cleaned(dict["UUID"] as? String)
        let platforms = (dict["Platform"] as? [String])?.compactMap(cleaned) ?? []
        let devices = (dict["ProvisionedDevices"] as? [Any])?.count
        guard name != nil || team != nil || appID != nil else { return nil }
        return Summary(
            isProvisioningProfile: true,
            subject: name,
            organization: team,
            issuer: nil,
            validFrom: created,
            expires: expires,
            isExpired: expires.map { $0 < now } ?? false,
            domains: [],
            team: team,
            appID: appID,
            uuid: uuid,
            platforms: platforms,
            provisionedDeviceCount: devices
        )
    }

    private static func extractDER(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex) else {
            return nil
        }
        let base64 = text[begin.upperBound..<end.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: base64)
    }

    private struct X509Fields {
        var subjectCN: String?
        var subjectOrg: String?
        var issuerCN: String?
        var issuerOrg: String?
        var notBefore: Date?
        var notAfter: Date?
        var dnsNames: [String] = []
    }

    private static func parseX509DER(_ data: Data) -> X509Fields? {
        var root = ASN1Cursor(data)
        guard var cert = root.readElement(expectedTag: 0x30)?.cursor,
              var tbs = cert.readElement(expectedTag: 0x30)?.cursor else { return nil }
        // Optional [0] EXPLICIT version
        if tbs.peekTag() == 0xA0 { _ = tbs.readElement() }
        // serialNumber (INTEGER)
        guard tbs.readElement(expectedTag: 0x02) != nil,
              // signature (AlgorithmIdentifier SEQUENCE)
              tbs.readElement(expectedTag: 0x30) != nil,
              // issuer (Name SEQUENCE)
              let issuerElem = tbs.readElement(expectedTag: 0x30),
              // validity (Validity SEQUENCE)
              let validityElem = tbs.readElement(expectedTag: 0x30),
              // subject (Name SEQUENCE)
              let subjectElem = tbs.readElement(expectedTag: 0x30) else { return nil }

        var fields = X509Fields()
        let issuerNames = parseDistinguishedName(issuerElem.cursor)
        fields.issuerCN = issuerNames.cn
        fields.issuerOrg = issuerNames.org

        var validity = validityElem.cursor
        fields.notBefore = validity.readElement().flatMap(parseASN1Time)
        fields.notAfter = validity.readElement().flatMap(parseASN1Time)

        let subjectNames = parseDistinguishedName(subjectElem.cursor)
        fields.subjectCN = subjectNames.cn
        fields.subjectOrg = subjectNames.org

        // Skip subjectPublicKeyInfo and optional issuerUniqueID / subjectUniqueID to reach [3] extensions
        while let elem = tbs.readElement() {
            if elem.tag == 0xA3 {
                var extWrapper = elem.cursor
                if var extSeq = extWrapper.readElement(expectedTag: 0x30)?.cursor {
                    while let ext = extSeq.readElement(expectedTag: 0x30) {
                        parseExtension(ext.cursor, into: &fields)
                    }
                }
            }
        }
        return fields
    }

    private static func parseDistinguishedName(_ sequence: ASN1Cursor) -> (cn: String?, org: String?) {
        var cursor = sequence
        var cn: String?, org: String?
        // OID 2.5.4.3 (commonName) = [0x55, 0x04, 0x03], OID 2.5.4.10 (organizationName) = [0x55, 0x04, 0x0A]
        while var rdnSet = cursor.readElement(expectedTag: 0x31)?.cursor {
            while var attr = rdnSet.readElement(expectedTag: 0x30)?.cursor {
                guard let oid = attr.readElement(expectedTag: 0x06),
                      let val = attr.readElement(),
                      let str = cleaned(String(data: val.bytes, encoding: .utf8) ?? String(data: val.bytes, encoding: .isoLatin1)) else {
                    continue
                }
                if oid.bytes.elementsEqual([0x55, 0x04, 0x03]), cn == nil { cn = str }
                else if oid.bytes.elementsEqual([0x55, 0x04, 0x0A]), org == nil { org = str }
            }
        }
        return (cn, org)
    }

    private static func parseExtension(_ sequence: ASN1Cursor, into fields: inout X509Fields) {
        var cursor = sequence
        // OID 2.5.29.17 (subjectAltName) = [0x55, 0x1D, 0x11]
        guard let oid = cursor.readElement(expectedTag: 0x06),
              oid.bytes.elementsEqual([0x55, 0x1D, 0x11]) else { return }
        while let next = cursor.readElement() {
            if next.tag == 0x04 {
                var octet = ASN1Cursor(next.bytes)
                guard var names = octet.readElement(expectedTag: 0x30)?.cursor else { return }
                while let entry = names.readElement() {
                    // dNSName is [2] IMPLICIT IA5String (tag 0x82)
                    if entry.tag == 0x82, fields.dnsNames.count < 32,
                       let dns = cleaned(String(data: entry.bytes, encoding: .utf8)),
                       !fields.dnsNames.contains(dns) {
                        fields.dnsNames.append(dns)
                    }
                }
            }
        }
    }

    private static func parseASN1Time(_ element: ASN1Element) -> Date? {
        guard (element.tag == 0x17 || element.tag == 0x18),
              let raw = String(data: element.bytes, encoding: .ascii) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if element.tag == 0x17 {
            formatter.dateFormat = raw.count == 13 ? "yyMMddHHmmss'Z'" : "yyMMddHHmm'Z'"
        } else {
            formatter.dateFormat = raw.count == 15 ? "yyyyMMddHHmmss'Z'" : "yyyyMMddHHmm'Z'"
        }
        return formatter.date(from: raw)
    }

    package static func cleanedName(_ text: String?) -> String? {
        cleaned(text)
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = DisplayText.oneLine(String(text.unicodeScalars.prefix(256)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated private struct ASN1Element {
    let tag: UInt8
    let bytes: Data
    var cursor: ASN1Cursor { ASN1Cursor(bytes) }
}

nonisolated private struct ASN1Cursor {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    func peekTag() -> UInt8? {
        offset < data.endIndex ? data[offset] : nil
    }

    mutating func readElement(expectedTag: UInt8? = nil) -> ASN1Element? {
        guard offset < data.endIndex else { return nil }
        let tag = data[offset]
        if let expectedTag, tag != expectedTag { return nil }
        offset += 1
        guard offset < data.endIndex else { return nil }
        let firstLen = Int(data[offset])
        offset += 1
        var length = 0
        if firstLen & 0x80 == 0 {
            length = firstLen
        } else {
            let byteCount = firstLen & 0x7F
            guard (1...4).contains(byteCount), offset + byteCount <= data.endIndex else { return nil }
            for _ in 0..<byteCount {
                length = (length << 8) | Int(data[offset])
                offset += 1
            }
        }
        guard length >= 0, length <= data.endIndex - offset else { return nil }
        let slice = data.subdata(in: offset..<(offset + length))
        offset += length
        return ASN1Element(tag: tag, bytes: slice)
    }
}

// MARK: - Apache Parquet (.parquet)

nonisolated package enum ParquetMetadata {
    package static let tailLimit = 512 * 1024
    package static let columnLimit = 500

    package struct Column: Equatable, Sendable {
        package let name: String
        package let physicalType: String
        package let repetition: String
        package let logicalType: String?
    }

    package struct Summary: Equatable, Sendable {
        package let version: Int
        package let rowCount: Int64
        package let rowGroupCount: Int
        package let columns: [Column]
        package let createdBy: String?
    }

    package static func read(_ url: URL) -> Summary? {
        guard url.pathExtension.lowercased() == "parquet",
              let (head, _) = try? TextFile.readPrefix(url, limit: 4),
              head == Data("PAR1".utf8),
              let (tail, fileSize) = try? TextFile.readSuffix(url, limit: tailLimit),
              fileSize >= 12, tail.count >= 8 else { return nil }
        return readFooter(from: tail)
    }

    package static func readFooter(from tail: Data) -> Summary? {
        guard tail.count >= 8,
              tail.suffix(4) == Data("PAR1".utf8) else { return nil }
        let lenStart = tail.endIndex - 8
        let footerLength = Int(UInt32(littleEndian: tail.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: lenStart - tail.startIndex, as: UInt32.self)
        }))
        guard footerLength > 0, footerLength + 8 <= tail.count else { return nil }
        let footerStart = lenStart - footerLength
        let footer = tail.subdata(in: footerStart..<lenStart)
        var reader = CompactThriftReader(footer)
        return parseFileMetaData(&reader)
    }

    private static func parseFileMetaData(_ reader: inout CompactThriftReader) -> Summary? {
        var lastField: Int16 = 0
        var version = 1
        var numRows: Int64 = 0
        var rowGroups = 0
        var createdBy: String?
        var rawElements: [(name: String, type: Int32?, repetition: Int32?, numChildren: Int32?, converted: Int32?)] = []

        fieldLoop: while let header = reader.readFieldHeader(lastField: &lastField) {
            switch (header.fieldID, header.type) {
            case (1, 5): // version: i32
                guard let v = reader.readZigZag32() else { return nil }
                version = Int(v)
            case (2, 9): // schema: list<SchemaElement>
                guard let list = reader.readListHeader(), list.count <= 2000 else { return nil }
                for _ in 0..<list.count {
                    guard let elem = parseSchemaElement(&reader) else { return nil }
                    rawElements.append(elem)
                }
            case (3, 6): // num_rows: i64
                guard let r = reader.readZigZag64(), r >= 0 else { return nil }
                numRows = r
            case (4, 9): // row_groups: list<RowGroup>
                guard let list = reader.readListHeader(), list.count <= 100_000 else {
                    if !rawElements.isEmpty { break fieldLoop }
                    return nil
                }
                rowGroups = list.count
                for _ in 0..<list.count {
                    guard reader.skipValue(type: list.elementType, depth: 0) else {
                        if !rawElements.isEmpty { break fieldLoop }
                        return nil
                    }
                }
            case (6, 8): // created_by: string
                createdBy = reader.readString()
            default:
                guard reader.skipValue(type: header.type, depth: 0) else {
                    if !rawElements.isEmpty { break fieldLoop }
                    return nil
                }
            }
        }

        // Leaf columns are SchemaElements past the root with no children.
        var columns: [Column] = []
        for (index, element) in rawElements.enumerated() where index > 0 {
            if (element.numChildren ?? 0) == 0, let typeCode = element.type, columns.count < columnLimit {
                columns.append(Column(
                    name: element.name,
                    physicalType: physicalTypeName(typeCode),
                    repetition: repetitionName(element.repetition),
                    logicalType: element.converted.flatMap(convertedTypeName)
                ))
            }
        }
        guard !columns.isEmpty || numRows > 0 else { return nil }
        return Summary(version: version, rowCount: numRows, rowGroupCount: rowGroups, columns: columns, createdBy: createdBy)
    }

    private static func parseSchemaElement(_ reader: inout CompactThriftReader) -> (name: String, type: Int32?, repetition: Int32?, numChildren: Int32?, converted: Int32?)? {
        var lastField: Int16 = 0
        var type: Int32?
        var repetition: Int32?
        var name = ""
        var numChildren: Int32?
        var converted: Int32?
        while let header = reader.readFieldHeader(lastField: &lastField) {
            switch (header.fieldID, header.type) {
            case (1, 5): type = reader.readZigZag32()
            case (3, 5): repetition = reader.readZigZag32()
            case (4, 8): name = reader.readString() ?? ""
            case (5, 5): numChildren = reader.readZigZag32()
            case (6, 5): converted = reader.readZigZag32()
            default:
                guard reader.skipValue(type: header.type, depth: 0) else { return nil }
            }
        }
        return (name, type, repetition, numChildren, converted)
    }

    private static func physicalTypeName(_ code: Int32) -> String {
        switch code {
        case 0: "BOOLEAN"
        case 1: "INT32"
        case 2: "INT64"
        case 3: "INT96"
        case 4: "FLOAT"
        case 5: "DOUBLE"
        case 6: "BYTE_ARRAY"
        case 7: "FIXED_LEN_BYTE_ARRAY"
        default: "TYPE_\(code)"
        }
    }

    private static func repetitionName(_ code: Int32?) -> String {
        switch code {
        case 0: "REQUIRED"
        case 1: "OPTIONAL"
        case 2: "REPEATED"
        default: "OPTIONAL"
        }
    }

    private static func convertedTypeName(_ code: Int32) -> String? {
        switch code {
        case 0: "UTF8"
        case 1: "MAP"
        case 3: "LIST"
        case 5: "DECIMAL"
        case 6: "DATE"
        case 7, 8: "TIME"
        case 9, 10: "TIMESTAMP"
        case 11: "UINT_8"
        case 12: "UINT_16"
        case 13: "UINT_32"
        case 14: "UINT_64"
        case 15: "INT_8"
        case 16: "INT_16"
        case 17: "INT_32"
        case 18: "INT_64"
        case 19: "JSON"
        case 20: "BSON"
        default: nil
        }
    }
}

nonisolated private struct CompactThriftReader {
    private let data: Data
    private var offset: Int
    private var stepsRemaining: Int = 500_000

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    private mutating func consumeStep() -> Bool {
        guard stepsRemaining > 0 else { return false }
        stepsRemaining -= 1
        return true
    }

    mutating func readByte() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readVarint64() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard let byte = readByte() else { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func readZigZag32() -> Int32? {
        guard let raw = readVarint64() else { return nil }
        let n = UInt32(truncatingIfNeeded: raw)
        return Int32(bitPattern: (n >> 1) ^ (0 &- (n & 1)))
    }

    mutating func readZigZag64() -> Int64? {
        guard let raw = readVarint64() else { return nil }
        return Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    mutating func readString() -> String? {
        guard let len = readVarint64(), len <= 65_536, Int(len) <= data.endIndex - offset else { return nil }
        let slice = data.subdata(in: offset..<(offset + Int(len)))
        offset += Int(len)
        return DisplayText.oneLine(String(decoding: slice, as: UTF8.self))
    }

    mutating func readFieldHeader(lastField: inout Int16) -> (fieldID: Int16, type: UInt8)? {
        guard consumeStep(), let byte = readByte() else { return nil }
        if byte == 0 { return nil }
        let delta = Int16((byte & 0xF0) >> 4)
        let type = byte & 0x0F
        let fieldID: Int16
        if delta == 0 {
            guard let id = readZigZag32() else { return nil }
            fieldID = Int16(clamping: id)
        } else {
            fieldID = lastField &+ delta
        }
        lastField = fieldID
        return (fieldID, type)
    }

    mutating func readListHeader() -> (elementType: UInt8, count: Int)? {
        guard consumeStep(), let byte = readByte() else { return nil }
        let elemType = byte & 0x0F
        let hi = Int((byte & 0xF0) >> 4)
        if hi < 15 { return (elemType, hi) }
        guard let count = readVarint64(), count <= 50_000 else { return nil }
        return (elemType, Int(count))
    }

    mutating func skipValue(type: UInt8, depth: Int) -> Bool {
        guard depth <= 16, consumeStep() else { return false }
        switch type {
        case 1, 2: // boolean true/false
            return true
        case 3: // byte
            return readByte() != nil
        case 4, 5, 6: // i16, i32, i64 (varint)
            return readVarint64() != nil
        case 7: // double (8 bytes)
            guard 8 <= data.endIndex - offset else { return false }
            offset += 8
            return true
        case 8: // binary / string
            guard let len = readVarint64(), len <= UInt64(data.endIndex - offset) else { return false }
            offset += Int(len)
            return true
        case 9, 10: // list, set
            guard let list = readListHeader() else { return false }
            for _ in 0..<list.count {
                if !skipValue(type: list.elementType, depth: depth + 1) { return false }
            }
            return true
        case 11: // map
            guard let count = readVarint64(), count <= 50_000 else { return false }
            if count == 0 { return true }
            guard let kvTypes = readByte() else { return false }
            let keyType = (kvTypes & 0xF0) >> 4
            let valType = kvTypes & 0x0F
            for _ in 0..<Int(count) {
                if !skipValue(type: keyType, depth: depth + 1) || !skipValue(type: valType, depth: depth + 1) { return false }
            }
            return true
        case 12: // struct
            var last: Int16 = 0
            while let field = readFieldHeader(lastField: &last) {
                if !skipValue(type: field.type, depth: depth + 1) { return false }
            }
            return true
        case 13: // uuid (16 bytes)
            guard 16 <= data.endIndex - offset else { return false }
            offset += 16
            return true
        default:
            return false
        }
    }
}

// MARK: - ML Weights & Arrays (.safetensors, .gguf, .npy)

nonisolated package enum MLHeaderMetadata {
    package static let extensions: Set<String> = ["safetensors", "gguf", "npy"]

    package struct Tensor: Equatable, Sendable {
        package let name: String
        package let shape: [Int]
        package let dtype: String
        package let parameters: Int64
    }

    package struct Summary: Equatable, Sendable {
        package let format: String
        package let modelName: String?
        package let architecture: String?
        package let precision: String?
        package let totalParameters: Int64?
        package let shapeDescription: String?
        package let tensors: [Tensor]
        package let sampleValues: [String]
    }

    package static func read(_ url: URL) -> Summary? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "safetensors": return readSafeTensors(url)
        case "gguf": return readGGUF(url)
        case "npy": return readNPY(url)
        default: return nil
        }
    }

    package static func readSafeTensors(_ url: URL) -> Summary? {
        guard let (head, _) = try? TextFile.readPrefix(url, limit: 8), head.count == 8 else { return nil }
        let headerLen = head.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard headerLen > 0, headerLen <= 4 * 1024 * 1024,
              let (full, _) = try? TextFile.readPrefix(url, limit: 8 + Int(headerLen)),
              full.count == 8 + Int(headerLen) else { return nil }
        return parseSafeTensorsHeader(full.subdata(in: 8..<full.count))
    }

    package static func parseSafeTensorsHeader(_ jsonBytes: Data) -> Summary? {
        guard let root = (try? JSONSerialization.jsonObject(with: jsonBytes)) as? [String: Any] else { return nil }
        var modelName: String?
        var architecture: String?
        if let meta = root["__metadata__"] as? [String: Any] {
            modelName = cleaned(meta["modelspec.title"] as? String ?? meta["model_name"] as? String ?? meta["name"] as? String)
            architecture = cleaned(meta["modelspec.architecture"] as? String ?? meta["architecture"] as? String)
        }
        var tensors: [Tensor] = []
        var dtypeCounts: [String: Int64] = [:]
        var totalParams: Int64 = 0
        for key in root.keys.sorted() where key != "__metadata__" {
            guard tensors.count < 5_000,
                  let info = root[key] as? [String: Any],
                  let rawDtype = info["dtype"] as? String,
                  let rawShape = info["shape"] as? [Any] else { continue }
            let shape = rawShape.compactMap(safeDimension)
            guard shape.count == rawShape.count, shape.count <= 16 else { continue }
            let params = parameterCount(of: shape)
            let dtype = normalizedDtype(rawDtype)
            totalParams = totalParams.saturatingAdd(params)
            dtypeCounts[dtype, default: 0] = dtypeCounts[dtype, default: 0].saturatingAdd(max(1, params))
            tensors.append(Tensor(name: DisplayText.oneLine(String(key.unicodeScalars.prefix(256))),
                                  shape: shape, dtype: dtype, parameters: params))
        }
        guard !tensors.isEmpty else { return nil }
        let dominantPrecision = dtypeCounts.max(by: { $0.value < $1.value })?.key
        return Summary(
            format: "SafeTensors",
            modelName: modelName,
            architecture: architecture,
            precision: dominantPrecision,
            totalParameters: totalParams > 0 ? totalParams : nil,
            shapeDescription: nil,
            tensors: tensors,
            sampleValues: []
        )
    }

    package static func readGGUF(_ url: URL) -> Summary? {
        guard let (data, _) = try? TextFile.readPrefix(url, limit: 8 * 1024 * 1024), data.count >= 24 else { return nil }
        return parseGGUFHeader(data)
    }

    package static func parseGGUFHeader(_ data: Data) -> Summary? {
        guard data.count >= 24, data.prefix(4) == Data("GGUF".utf8) else { return nil }
        var offset = 4
        func readU32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            defer { offset += 4 }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        func readU64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            defer { offset += 8 }
            return data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }
        func readString() -> String? {
            guard let len = readU64(), len <= 65_536, offset + Int(len) <= data.count else { return nil }
            let slice = data.subdata(in: offset..<(offset + Int(len)))
            offset += Int(len)
            return DisplayText.oneLine(String(decoding: slice, as: UTF8.self))
        }
        var skipSteps = 500_000
        func skipGGUFValue(type: UInt32, depth: Int) -> Bool {
            guard depth <= 4, skipSteps > 0 else { return false }
            skipSteps -= 1
            switch type {
            case 0, 1, 7: // uint8, int8, bool
                guard offset + 1 <= data.count else { return false }; offset += 1; return true
            case 2, 3: // uint16, int16
                guard offset + 2 <= data.count else { return false }; offset += 2; return true
            case 4, 5, 6: // uint32, int32, float32
                guard offset + 4 <= data.count else { return false }; offset += 4; return true
            case 8: // string
                guard let len = readU64(), len <= 65_536, offset + Int(len) <= data.count else { return false }
                offset += Int(len)
                return true
            case 9: // array
                guard let elemType = readU32(), let count = readU64(), count <= 500_000 else { return false }
                switch elemType {
                case 0, 1, 7:
                    guard Int(count) <= data.count - offset else { return false }
                    offset += Int(count)
                    return true
                case 2, 3:
                    guard Int(count) * 2 <= data.count - offset else { return false }
                    offset += Int(count) * 2
                    return true
                case 4, 5, 6:
                    guard Int(count) * 4 <= data.count - offset else { return false }
                    offset += Int(count) * 4
                    return true
                case 10, 11, 12:
                    guard Int(count) * 8 <= data.count - offset else { return false }
                    offset += Int(count) * 8
                    return true
                default:
                    for _ in 0..<Int(count) {
                        if !skipGGUFValue(type: elemType, depth: depth + 1) { return false }
                    }
                    return true
                }
            case 10, 11, 12: // uint64, int64, float64
                guard offset + 8 <= data.count else { return false }; offset += 8; return true
            default:
                return false
            }
        }

        guard let version = readU32(), (2...3).contains(version),
              let tensorCount = readU64(), tensorCount <= 100_000,
              let kvCount = readU64(), kvCount <= 4_096 else { return nil }

        var modelName: String?
        var architecture: String?
        var fileTypeCode: UInt32?
        var kvComplete = true
        for _ in 0..<Int(kvCount) {
            guard let key = readString(), let valType = readU32() else {
                kvComplete = false
                break
            }
            if valType == 8, (key == "general.name" || key == "general.architecture") {
                guard let str = readString() else {
                    kvComplete = false
                    break
                }
                if key == "general.name" { modelName = cleaned(str) }
                else { architecture = cleaned(str) }
            } else if valType == 4, key == "general.file_type" {
                guard let ft = readU32() else {
                    kvComplete = false
                    break
                }
                fileTypeCode = ft
            } else if !skipGGUFValue(type: valType, depth: 0) {
                kvComplete = false
                break
            }
        }

        var tensors: [Tensor] = []
        var totalParams: Int64 = 0
        var typeCounts: [String: Int64] = [:]
        if kvComplete {
            for _ in 0..<min(Int(tensorCount), 2_000) {
                guard let name = readString(), let nDims = readU32(), nDims <= 8 else { break }
                var shape: [Int] = []
                var ok = true
                for _ in 0..<Int(nDims) {
                    guard let dim = readU64(), dim <= UInt64(Int.max) else { ok = false; break }
                    shape.append(Int(dim))
                }
                guard ok, let ggmlType = readU32(), readU64() != nil else { break }
                let dtype = ggmlTypeName(ggmlType)
                let params = parameterCount(of: shape)
                totalParams = totalParams.saturatingAdd(params)
                typeCounts[dtype, default: 0] = typeCounts[dtype, default: 0].saturatingAdd(max(1, params))
                tensors.append(Tensor(name: name, shape: shape, dtype: dtype, parameters: params))
            }
        }
        let dominantPrecision = fileTypeCode.flatMap(ggufFileTypeName) ?? typeCounts.max(by: { $0.value < $1.value })?.key
        guard !tensors.isEmpty || modelName != nil || architecture != nil || dominantPrecision != nil else { return nil }
        return Summary(
            format: "GGUF",
            modelName: modelName,
            architecture: architecture,
            precision: dominantPrecision,
            totalParameters: totalParams > 0 ? totalParams : nil,
            shapeDescription: nil,
            tensors: tensors,
            sampleValues: []
        )
    }

    package static func readNPY(_ url: URL) -> Summary? {
        guard let (data, _) = try? TextFile.readPrefix(url, limit: 64 * 1024), data.count >= 10 else { return nil }
        return parseNPYHeader(data)
    }

    package static func parseNPYHeader(_ data: Data) -> Summary? {
        guard data.count >= 10,
              data.prefix(6).elementsEqual([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else { return nil }
        let major = data[6]
        let headerOffset: Int
        let headerLen: Int
        if major == 1 {
            headerLen = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt16.self) }))
            headerOffset = 10
        } else if major == 2 || major == 3 {
            guard data.count >= 12 else { return nil }
            headerLen = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }))
            headerOffset = 12
        } else {
            return nil
        }
        guard headerLen > 0, headerLen <= 32_768, headerOffset + headerLen <= data.count,
              let headerText = String(data: data.subdata(in: headerOffset..<(headerOffset + headerLen)), encoding: .utf8) else {
            return nil
        }
        let descr = extractQuotedValue(after: "'descr'", in: headerText) ?? extractQuotedValue(after: "\"descr\"", in: headerText)
        guard let descr else { return nil }
        let shape = extractShapeTuple(in: headerText)
        let dtype = numpyDtypeName(descr)
        let params = parameterCount(of: shape)
        let shapeText = shape.isEmpty ? "scalar" : shape.map { $0.formatted() }.joined(separator: " × ")
        let payload = data.dropFirst(headerOffset + headerLen)
        let samples = readNPYSamples(payload: payload, descr: descr, maxCount: min(Int(clamping: params), 200))
        return Summary(
            format: "NumPy",
            modelName: nil,
            architecture: nil,
            precision: dtype,
            totalParameters: params > 0 ? params : nil,
            shapeDescription: shapeText,
            tensors: [Tensor(name: "array", shape: shape, dtype: dtype, parameters: params)],
            sampleValues: samples
        )
    }

    package static func formatParameterCount(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return (Double(count) / 1_000_000_000).formatted(.number.precision(.fractionLength(0...2))) + "B"
        }
        if count >= 1_000_000 {
            return (Double(count) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + "M"
        }
        if count >= 1_000 {
            return (Double(count) / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "K"
        }
        return count.formatted()
    }

    private static func safeDimension(_ raw: Any) -> Int? {
        if let intVal = raw as? Int {
            return intVal >= 0 ? intVal : nil
        }
        if let num = raw as? NSNumber {
            let d = num.doubleValue
            guard d.isFinite, d >= 0, d <= Double(Int32.max), d.rounded() == d else { return nil }
            return Int(d)
        }
        return nil
    }

    private static func parameterCount(of shape: [Int]) -> Int64 {
        guard !shape.isEmpty else { return 1 }
        var product: Int64 = 1
        for dim in shape {
            guard dim >= 0 else { return 0 }
            let (next, overflow) = product.multipliedReportingOverflow(by: Int64(dim))
            if overflow { return Int64.max }
            product = next
        }
        return product
    }

    private static func normalizedDtype(_ raw: String) -> String {
        switch raw.uppercased() {
        case "F16": "FP16"
        case "BF16": "BF16"
        case "F32": "FP32"
        case "F64": "FP64"
        case "I8", "U8": "INT8"
        case "I16", "U16": "INT16"
        case "I32", "U32": "INT32"
        case "I64", "U64": "INT64"
        case "F8_E4M3", "F8_E5M2": "FP8"
        case "BOOL": "BOOL"
        default: raw
        }
    }

    private static func ggmlTypeName(_ code: UInt32) -> String {
        switch code {
        case 0: "FP32"
        case 1: "FP16"
        case 2: "Q4_0"
        case 3: "Q4_1"
        case 6: "Q5_0"
        case 7: "Q5_1"
        case 8: "Q8_0"
        case 9: "Q8_1"
        case 10: "Q2_K"
        case 11: "Q3_K"
        case 12: "Q4_K"
        case 13: "Q5_K"
        case 14: "Q6_K"
        case 15: "Q8_K"
        case 30: "BF16"
        default: "Type \(code)"
        }
    }

    private static func ggufFileTypeName(_ code: UInt32) -> String? {
        switch code {
        case 0: "FP32"
        case 1: "FP16"
        case 2: "Q4_0"
        case 3: "Q4_1"
        case 7: "Q8_0"
        case 10: "Q2_K"
        case 12: "Q3_K_M"
        case 15: "Q4_K_M"
        case 17: "Q5_K_M"
        case 18: "Q6_K"
        case 32: "BF16"
        default: nil
        }
    }

    private static func numpyDtypeName(_ descr: String) -> String {
        let core = descr.trimmingCharacters(in: CharacterSet(charactersIn: "<>|="))
        return switch core {
        case "f2": "float16"
        case "f4": "float32"
        case "f8": "float64"
        case "i1": "int8"
        case "i2": "int16"
        case "i4": "int32"
        case "i8": "int64"
        case "u1": "uint8"
        case "u2": "uint16"
        case "u4": "uint32"
        case "u8": "uint64"
        case "b1": "bool"
        default: descr
        }
    }

    private static func extractQuotedValue(after key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: key) else { return nil }
        let rest = text[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let afterColon = rest[rest.index(after: colon)...].drop(while: \.isWhitespace)
        guard let quote = afterColon.first, quote == "'" || quote == "\"" else { return nil }
        let body = afterColon.dropFirst()
        guard let endQuote = body.firstIndex(of: quote) else { return nil }
        return String(body[..<endQuote])
    }

    private static func extractShapeTuple(in text: String) -> [Int] {
        guard let range = text.range(of: "'shape'") ?? text.range(of: "\"shape\""),
              let open = text[range.upperBound...].firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else { return [] }
        let inside = text[text.index(after: open)..<close]
        return inside.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func readNPYSamples(payload: Data, descr: String, maxCount: Int) -> [String] {
        guard maxCount > 0, !descr.hasPrefix(">") else { return [] }
        let core = descr.trimmingCharacters(in: CharacterSet(charactersIn: "<|="))
        var values: [String] = []
        var cursor = ByteCursor(Data(payload))
        for _ in 0..<maxCount {
            switch core {
            case "f4":
                guard let bits: UInt32 = try? cursor.read() else { return values }
                values.append(Float(bitPattern: bits).formatted(.number.precision(.significantDigits(1...6))))
            case "f8":
                guard let bits: UInt64 = try? cursor.read() else { return values }
                values.append(Double(bitPattern: bits).formatted(.number.precision(.significantDigits(1...8))))
            case "i4":
                guard let bits: UInt32 = try? cursor.read() else { return values }
                values.append(Int32(bitPattern: bits).formatted())
            case "i8":
                guard let bits: UInt64 = try? cursor.read() else { return values }
                values.append(Int64(bitPattern: bits).formatted())
            case "u1":
                guard let byte: UInt8 = try? cursor.read() else { return values }
                values.append(byte.formatted())
            default:
                return values
            }
        }
        return values
    }

    package static func cleanedName(_ text: String?) -> String? {
        cleaned(text)
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = DisplayText.oneLine(String(text.unicodeScalars.prefix(256)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private nonisolated struct ByteCursor {
    struct Truncated: Error {}
    private let bytes: Data
    private(set) var offset = 0

    init(_ bytes: Data) { self.bytes = bytes }
    var remaining: Int { bytes.count - offset }

    mutating func read<Value: FixedWidthInteger & UnsignedInteger>(_: Value.Type = Value.self) throws -> Value {
        let size = MemoryLayout<Value>.size
        guard size <= remaining else { throw Truncated() }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Value.self) }
        offset += size
        return Value(littleEndian: value)
    }
}

// MARK: - macOS Application Bundles (.app)

nonisolated package enum AppBundleMetadata {
    package enum Architecture: Equatable, Sendable {
        case appleSilicon
        case universal
        case intel
    }

    package struct Summary: Equatable, Sendable {
        package let version: String?
        package let architecture: Architecture?
        package let minimumSystemVersion: String?
        package let signedBy: String?
    }

    package static func read(_ url: URL) -> Summary? {
        guard url.pathExtension.lowercased() == "app",
              !DatalessFile.isDataless(url.path),
              !DatalessFile.containsDataless(url) else { return nil }
        return DatalessFile.withoutMaterializing {
            let infoURL = url.appending(path: "Contents/Info.plist")
            guard let (plistData, truncated) = try? TextFile.readPrefix(infoURL, limit: 512 * 1024),
                  !truncated, !plistData.isEmpty,
                  isSafePropertyListData(plistData),
                  let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any] else {
                return nil
            }
            let shortVersion = cleaned(plist["CFBundleShortVersionString"] as? String)
            let buildVersion = cleaned(plist["CFBundleVersion"] as? String)
            let version: String? = switch (shortVersion, buildVersion) {
            case let (short?, build?) where short != build && !short.contains(build):
                "\(short) (\(build))"
            case let (short?, _):
                short
            case let (nil, build?):
                build
            default:
                nil
            }
            let minOS = cleaned(plist["LSMinimumSystemVersion"] as? String)
            let executable = cleaned(plist["CFBundleExecutable"] as? String)
            let arch = executable.flatMap { name -> Architecture? in
                guard !name.contains("/"), !name.contains("..") else { return nil }
                let binURL = url.appending(path: "Contents/MacOS").appending(path: name)
                return readMachOArchitecture(binURL)
            }
            let signedBy = arch != nil ? readSigningAuthority(url) : nil
            guard version != nil || arch != nil || minOS != nil || signedBy != nil else { return nil }
            return Summary(version: version, architecture: arch, minimumSystemVersion: minOS, signedBy: signedBy)
        }
    }

    package static func readMachOArchitecture(_ url: URL) -> Architecture? {
        guard let (head, _) = try? TextFile.readPrefix(url, limit: 128), head.count >= 8 else { return nil }
        let magic = head.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        switch magic {
        case 0xFEEDFACF, 0xFEEDFACE:
            let cpu = head.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
            if cpu == 0x0100_000C { return .appleSilicon }
            if cpu == 0x0100_0007 || cpu == 7 { return .intel }
            return nil
        case 0xBEBAFECA, 0xCAFEBABE:
            // Fat header is big-endian
            let count = Int(head.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
            guard (1...8).contains(count), head.count >= 8 + count * 20 else { return nil }
            var hasArm = false, hasIntel = false
            for index in 0..<count {
                let cpu = head.withUnsafeBytes {
                    UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 8 + index * 20, as: UInt32.self))
                }
                if cpu == 0x0100_000C { hasArm = true }
                else if cpu == 0x0100_0007 || cpu == 7 { hasIntel = true }
            }
            if hasArm && hasIntel { return .universal }
            if hasArm { return .appleSilicon }
            if hasIntel { return .intel }
            return nil
        default:
            return nil
        }
    }

    private static func readSigningAuthority(_ url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certs.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String?,
           let cleanedSummary = cleaned(summary) {
            return cleanedSummary
        }
        if let team = cleaned(info[kSecCodeInfoTeamIdentifier as String] as? String) {
            return team
        }
        return nil
    }

    package static func cleanedName(_ text: String?) -> String? {
        cleaned(text)
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = DisplayText.oneLine(String(text.unicodeScalars.prefix(256)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private nonisolated func hasAllowedXMLEncoding(_ text: String) -> Bool {
    if text.contains("+ADw-") { return false }
    let header = String(text.prefix(1024))
    guard let xmlStart = header.range(of: "<?xml", options: .caseInsensitive) else { return true }
    let rest = header[xmlStart.upperBound...]
    let declEnd = rest.range(of: "?>")?.lowerBound ?? rest.endIndex
    let decl = rest[..<declEnd]
    guard let encRange = decl.range(of: "encoding", options: .caseInsensitive) else { return true }
    let afterEnc = decl[encRange.upperBound...].drop(while: \.isWhitespace)
    guard afterEnc.first == "=" else { return false }
    let afterEq = afterEnc.dropFirst().drop(while: \.isWhitespace)
    guard let quote = afterEq.first, quote == "\"" || quote == "'" else { return false }
    let body = afterEq.dropFirst()
    guard let endQuote = body.firstIndex(of: quote) else { return false }
    let encoding = body[..<endQuote].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return encoding == "utf-8" || encoding == "utf8" || encoding == "us-ascii" || encoding == "ascii"
}

private nonisolated func isSafePropertyListData(_ data: Data) -> Bool {
    if data.starts(with: Data("bplist".utf8)) { return true }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0x00, 0x00]) {
        return false
    }
    let text = String(decoding: data, as: UTF8.self)
    guard hasAllowedXMLEncoding(text) else { return false }
    if text.localizedCaseInsensitiveContains("<!ENTITY") { return false }
    if let doctypeRange = text.range(of: "<!DOCTYPE", options: .caseInsensitive),
       text[doctypeRange.upperBound...].prefix(4096).contains("[") {
        return false
    }
    return true
}

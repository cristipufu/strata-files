import Foundation
import StrataArchives
import StrataModel

/// Only bounded model parts cross from the archive worker to the isolated WebKit parser.
nonisolated enum ThreeMFPackage {
    static let archiveByteLimit: Int64 = 64 << 20
    static let modelLimit = 32
    static let xmlByteLimit = 32 << 20
    static let payloadByteLimit = 64 << 20
    private static let relationshipsPath = ["_rels", ".rels"]
    private struct Payload: Encodable {
        let relationships: String
        let parts: [String: String]
    }

    @concurrent static func read(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let source = try FileReadSource(url)
        guard source.size <= archiveByteLimit else { throw tooLarge }
        let records = try await ArchiveReader.read(source)
        let models = records.filter { $0.path.last?.lowercased().hasSuffix(".model") == true }
        guard !models.isEmpty else { throw PreviewError.unsupported }
        guard models.count <= modelLimit else { throw tooLarge }
        var total = 0
        for model in models {
            guard model.kind == 1, model.size >= 0 else { throw PreviewError.unsupported }
            guard model.size <= ModelDocument.byteLimit,
                  model.size <= xmlByteLimit - total else { throw tooLarge }
            total += Int(model.size)
        }
        let relationships = try await PackagePart.read(source, records: records, path: relationshipsPath, limit: 1 << 20)
        var parts: [String: String] = [:]
        var remaining = xmlByteLimit
        for model in models {
            try Task.checkCancellation()
            let data = try await PackagePart.read(source, records: records, path: model.path,
                                                  limit: min(ModelDocument.byteLimit, remaining))
            remaining -= data.count
            parts[model.path.joined(separator: "/")] = data.base64EncodedString()
        }
        let data = try JSONEncoder().encode(Payload(relationships: relationships.base64EncodedString(), parts: parts))
        guard data.count <= payloadByteLimit else { throw tooLarge }
        try Task.checkCancellation()
        return data
    }

    private static var tooLarge: PreviewError { .message(String(localized: "This model is too large to preview.")) }
}

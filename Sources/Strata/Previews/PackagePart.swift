import Foundation
import StrataArchives

nonisolated enum PackagePart {
    static func read(_ source: ArchiveSource, records: [ArchiveRecord], path: [String], limit: Int) async throws -> Data {
        let key = path.joined(separator: "/")
        guard let record = records.first(where: { $0.path.joined(separator: "/").utf8.elementsEqual(key.utf8) }),
              record.kind == 1, record.size >= 0, record.size <= limit else { throw PreviewError.unsupported }
        let selected = try await ArchiveReader.read(source, member: path)
        guard selected.count == 1, let data = selected[0].body, data.count <= limit else { throw PreviewError.unsupported }
        return data
    }
}

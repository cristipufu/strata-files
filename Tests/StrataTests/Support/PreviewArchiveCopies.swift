import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension PreviewArchiveAccess {
    /// An access whose preview copies are what `reader` reads, asking for a password when it does.
    convenience init(copying reader: @escaping Reader) {
        self.init(reader: reader, copier: { source, member, folder, password, cached in
            let body = try #require(try await reader(source, member, false, password).first?.body)
            return try await PreviewArchiveLease.stream(member: member, in: folder, source: source, password: password,
                                                        cached: cached) {
                _, _, _, open in
                let sink = try open(Int64(body.count))
                try body.withUnsafeBytes { try sink($0) }
            }
        })
    }
}

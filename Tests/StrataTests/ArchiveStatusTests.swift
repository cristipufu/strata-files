import Foundation
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataQueue

/// A finished Compress says the zip's name and size, read where the zip was made, never on the main thread as the
/// Transfers list draws it.
@MainActor struct ArchiveStatusTests {
    @Test func aFinishedCompressSaysTheZipsNameAndSize() async throws {
        let tree = try TestTree("a.txt"), state = try TestTree()
        let environment = try PreviewEnvironment(state)
        let job = ArchiveJob(.compress([tree.url("a.txt")]), undo: nil)
        environment.services.transfers.add(job)
        await job.finished()
        let zip = try #require(job.result)
        let size = try #require(try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(job.statusText.contains(zip.lastPathComponent) && job.statusText.contains(Format.bytes(Int64(size))))
        #expect(tree.snapshot() == ["a.txt", zip.lastPathComponent].sorted())
    }
}

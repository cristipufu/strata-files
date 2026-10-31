import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

@Suite(.archiveWorkerApp)
struct PreviewArchiveRootTests {
    @Test func tarRootDirectoriesAreSkippedWhileChosenMembersRemainExact() async throws {
        for root in [".", "./.", "./", "././."] {
            let tree = try TestTree("pack.tar", "outside/keep", "sibling")
            let data = Data(ContainerTests.tarHeader(root, type: UInt8(ascii: "5"), mode: 0o755)
                            + ContainerTests.tarFile("./a.txt", "chosen") + ContainerTests.tarFile("./ab.txt", "other")
                            + [UInt8](repeating: 0, count: 1024))
            try data.write(to: tree.url("pack.tar"))
            let before = tree.snapshot(), source = try PreviewArchiveSource(tree.url("pack.tar"))
            let listed = try await PreviewArchiveReader.read(source)
            #expect(listed.map(\.path) == [["a.txt"], ["ab.txt"]])
            let selected = try await PreviewArchiveReader.read(source, member: ["a.txt"])
            #expect(selected.count == 1 && selected.first?.path == ["a.txt"] && selected.first?.body == Data("chosen".utf8))
            #expect(try Data(contentsOf: tree.url("pack.tar")) == data && tree.snapshot() == before)
        }
    }

    @Test func rootAliasesNeverHideFilesLinksOrAbsolutePaths() async throws {
        for name in [".", "./.", "./", "/"] {
            for type: UInt8 in [UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "6"), UInt8(ascii: "5")] {
                if type == UInt8(ascii: "5"), name != "/" { continue }
                // libarchive classifies an empty regular header ending in / as a directory.
                if type == UInt8(ascii: "0"), name == "./" { continue }
                let tree = try TestTree("pack.tar", "outside/keep", "sibling")
                let data = Data(ContainerTests.tarHeader(name, type: type, link: "../outside/keep")
                                + ContainerTests.tarFile("a.txt", "chosen") + [UInt8](repeating: 0, count: 1024))
                try data.write(to: tree.url("pack.tar"))
                let source = try PreviewArchiveSource(tree.url("pack.tar")), before = tree.snapshot()
                await #expect(throws: PreviewArchiveError.unsafe) { try await PreviewArchiveReader.read(source) }
                await #expect(throws: PreviewArchiveError.unsafe) { try await PreviewArchiveReader.read(source, member: ["a.txt"]) }
                #expect(try Data(contentsOf: tree.url("pack.tar")) == data && tree.snapshot() == before)
            }
        }
    }

    @Test func legacySlashTerminatedTarDirectoriesKeepTheirDirectoryMeaning() async throws {
        let tree = try TestTree("pack.tar", "outside/keep", "sibling")
        let data = Data(ContainerTests.tarHeader("./") + ContainerTests.tarFile("a.txt", "chosen")
                        + [UInt8](repeating: 0, count: 1024))
        try data.write(to: tree.url("pack.tar"))
        let source = try PreviewArchiveSource(tree.url("pack.tar")), before = tree.snapshot()
        #expect(try await PreviewArchiveReader.read(source).map(\.path) == [["a.txt"]])
        let selected = try await PreviewArchiveReader.read(source, member: ["a.txt"])
        #expect(selected.first?.body == Data("chosen".utf8))
        #expect(try Data(contentsOf: tree.url("pack.tar")) == data && tree.snapshot() == before)
    }

    @Test func systemCpioRootDirectoriesKeepTheirChildrenPreviewable() async throws {
        for root in [".", "./."] {
            let tree = try TestTree("source/a.txt", "source/ab.txt", "pack.cpio", "outside/keep")
            let archive = try await cpio(in: tree.url("source"), root: root)
            try archive.write(to: tree.url("pack.cpio"))
            let before = tree.snapshot(), source = try PreviewArchiveSource(tree.url("pack.cpio"))
            let listed = try await PreviewArchiveReader.read(source)
            #expect(listed.map(\.path) == [["a.txt"], ["ab.txt"]])
            let selected = try await PreviewArchiveReader.read(source, member: ["a.txt"])
            #expect(selected.count == 1 && selected.first?.body == Data("source/a.txt".utf8))
            #expect(try Data(contentsOf: tree.url("pack.cpio")) == archive && tree.snapshot() == before)
        }
    }

    private func cpio(in directory: URL, root: String) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                do {
                    let process = Process(), input = Pipe(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/cpio")
                    process.arguments = ["-o", "-H", "newc"]
                    process.currentDirectoryURL = directory
                    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: Data((root + "\na.txt\nab.txt\n").utf8))
                    try input.fileHandleForWriting.close()
                    let data = try output.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                    done.resume(returning: data)
                } catch { done.resume(throwing: error) }
            }
        }
    }
}

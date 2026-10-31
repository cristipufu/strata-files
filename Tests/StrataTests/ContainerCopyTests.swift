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

/// Writing a container's folder into its copy on this Mac, from the tar stream the engine sends, which the container
/// decides. Nothing it holds may reach outside the copy: no `..`, nothing written through a link, no hard link to a file
/// elsewhere; and what the container no longer has is removed from the copy alone, never through a link.
extension ContainerTests {
    /// Two bounded replies: the tree and a hardlink's independently fetched contents. A mutant that omits the
    /// second request cannot leave a test thread blocked in accept forever.
    private static func hardlinkServer(_ streams: [[UInt8]]) throws -> ContainerEngine {
        let path = "/tmp/strata-hardlink-\(UUID().uuidString.prefix(8)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(result == 0)
        listen(listener, 2)
        Thread.detachNewThread {
            defer { close(listener); unlink(path) }
            for stream in streams {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 2000) > 0 else { return }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var request = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while !request.contains(Data("\r\n\r\n".utf8)) {
                    let count = recv(client, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                    request.append(contentsOf: buffer[..<count])
                }
                let body = stream + [UInt8](repeating: 0, count: 1024)
                let reply = Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
                _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                close(client)
            }
        }
        return ContainerEngine(socket: path, name: "Fixture", apiVersion: "1.41")
    }

    @Test(arguments: ["absolute", "stale"])
    func hardlinksUseContainerPathsAndNeverReuseAnUnfetchedPlaceholder(_ kind: String) async throws {
        let tree = try TestTree("copy/etc/", "copy/etc/stale", "outside/", "outside/keep")
        #expect(chmod(tree.url("copy/etc/stale").path, 0) == 0)
        var stream = Self.tarHeader("etc/", type: UInt8(ascii: "5"), mode: 0o755)
        stream += Self.tarFile("etc/passwd", "inside subfolder")
        stream += Self.tarHeader("etc/hard", type: UInt8(ascii: "1"), link: kind == "absolute" ? "/etc/passwd" : "etc/stale")
        let engine = try Self.hardlinkServer([stream, Self.tarFile("hard", "remote target")])
        let destination = tree.url("copy/etc")
        let result = await TransferWorker(label: "strata-test-hardlinks").run {
            Result { try CopyWriter.writeTree(engine, id: String(repeating: "ab", count: 32), containerPath: "/home/app/etc",
                                             into: destination, stop: StopFlag()) }
        }
        try result.get()
        #expect(tree.text("copy/etc/hard") == "remote target")
        #expect(tree.text("copy/etc/passwd") == "inside subfolder")
        #expect(tree.snapshot() == ["copy/", "copy/etc/", "copy/etc/hard", "copy/etc/passwd", "outside/", "outside/keep"])
    }

    private static let id = String(repeating: "ab", count: 32)

    private static func archive(_ stream: [UInt8], beforeReply: (@Sendable () -> Void)? = nil) throws -> ContainerEngine {
        let body = stream + [UInt8](repeating: 0, count: 1024)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-tar\r\nContent-Length: \(body.count)\r\n\r\n"
        let response = Array(head.utf8) + body
        guard let beforeReply else {
            let server = try serve(response)
            return ContainerEngine(socket: server.path, name: "Docker", apiVersion: "1.41")
        }
        let path = "/tmp/strata-test-\(UUID().uuidString.prefix(8)).sock"
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        listen(server, 1)
        Thread.detachNewThread {
            let client = accept(server, nil, nil)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains(Data("\r\n\r\n".utf8)) {
                let count = recv(client, &buffer, buffer.count, 0)
                if count <= 0 { break }
                request.append(contentsOf: buffer[0..<count])
            }
            beforeReply()
            _ = response.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            close(client)
            close(server)
            unlink(path)
        }
        return ContainerEngine(socket: path, name: "Docker", apiVersion: "1.41")
    }

    @Test func aContainersFolderIsWrittenOnlyIntoItsCopy() throws {
        // `root` is the container's copy (its `/`); `data` the folder being written; `outside` is beside the copy.
        let tree = try TestTree("outside/", "outside/secret.txt", "outside/keep/", "outside/keep/inner.txt",
                                "root/", "root/data/", "root/data/ok.txt", "root/data/stale.txt", "root/data/old link -> ../../outside")
        var stream = Self.tarHeader("data/", type: UInt8(ascii: "5"), mode: 0o755)
        stream += Self.tarFile("data/ok.txt", "fresh")
        // Out of the folder, or only named like it.
        stream += Self.tarFile("data/../escape.txt", "x")
        stream += Self.tarFile("data/sub/../../escape.txt", "x")
        stream += Self.tarFile("/etc/absolute.txt", "x")
        stream += Self.tarFile("data2/sibling.txt", "x")
        // A link leading out is kept inside the copy; a file "in" it goes into a real folder that takes its place.
        stream += Self.tarHeader("data/up", type: UInt8(ascii: "2"), link: "../../../../outside")
        stream += Self.tarFile("data/up/through.txt", "x")
        stream += Self.tarHeader("data/door", type: UInt8(ascii: "2"), link: "/")
        // Hard links: only to what's in the stream's own folder.
        stream += Self.tarHeader("data/hard", type: UInt8(ascii: "1"), link: "data/ok.txt")
        stream += Self.tarHeader("data/hard out", type: UInt8(ascii: "1"), link: "data/../../outside/secret.txt")
        stream += Self.tarHeader("data/hard etc", type: UInt8(ascii: "1"), link: "etc/passwd")
        try CopyWriter.writeTree(try Self.archive(stream), id: Self.id, containerPath: "/data", into: tree.url("root/data"),
                                 stop: StopFlag())
        let copy = tree.snapshot().filter { $0.hasPrefix("root/") }
        #expect(copy == ["root/", "root/data/", "root/data/door -> ..", "root/data/hard", "root/data/ok.txt",
                         "root/data/up/", "root/data/up/through.txt"])
        #expect(tree.text("root/data/ok.txt") == "fresh" && tree.text("root/data/hard") == "fresh")
        // Beside the copy, nothing changed.
        #expect(tree.snapshot().filter { !$0.hasPrefix("root/") } == ["outside/", "outside/keep/", "outside/keep/inner.txt", "outside/secret.txt"])
        #expect(tree.text("outside/secret.txt") == "outside/secret.txt")
    }

    @Test func aCopyThatIsALinkIsNotWrittenThrough() throws {
        let tree = try TestTree("outside/", "outside/secret.txt", "root/", "root/data -> ../outside")
        var stream = Self.tarHeader("data/", type: UInt8(ascii: "5"), mode: 0o755)
        stream += Self.tarFile("data/new.txt", "x")
        #expect(throws: (any Error).self) {
            try CopyWriter.writeTree(try Self.archive(stream), id: Self.id, containerPath: "/data", into: tree.url("root/data"),
                                     stop: StopFlag())
        }
        #expect(tree.snapshot() == ["outside/", "outside/secret.txt", "root/", "root/data -> ../outside"])
    }

    // MARK: - One file

    /// A file not fetched yet, as a listing leaves it: a regular file without permissions.
    private func placeholder(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0])
    }

    @Test func aFetchedFileTakesOnlyItsPlaceholdersPlace() throws {
        let tree = try TestTree("copy/", "copy/other.txt", "outside/", "outside/secret.txt")
        placeholder(tree.url("copy/hosts"))
        // Only the stream's first entry counts; nothing else in it is written anywhere.
        let stream = Self.tarFile("hosts", "127.0.0.1 localhost\n") + Self.tarFile("../escape.txt", "x") + Self.tarFile("other.txt", "x")
        try CopyWriter.fetchFile(try Self.archive(stream), id: Self.id, containerPath: "/etc/hosts", to: tree.url("copy/hosts"), stop: StopFlag())
        #expect(tree.text("copy/hosts") == "127.0.0.1 localhost\n" && tree.text("copy/other.txt") == "copy/other.txt")
        #expect(tree.snapshot() == ["copy/", "copy/hosts", "copy/other.txt", "outside/", "outside/secret.txt"])
    }

    @Test func aFetchThatIsntAFileOrFindsSomethingElseChangesNothing() throws {
        let tree = try TestTree("copy/", "copy/now a folder/", "copy/now a folder/inside.txt", "copy/now a link -> ../outside/secret.txt",
                                "copy/already.txt", "outside/", "outside/secret.txt")
        placeholder(tree.url("copy/hosts"))
        // The container sends a link (or a folder) where a file was listed: nothing is written.
        let link = Self.tarHeader("hosts", type: UInt8(ascii: "2"), link: "/etc/passwd")
        #expect(throws: (any Error).self) {
            try CopyWriter.fetchFile(try Self.archive(link), id: Self.id, containerPath: "/etc/hosts", to: tree.url("copy/hosts"), stop: StopFlag())
        }
        // Listed again meanwhile, the placeholder is a folder, link, already-fetched file, or a new placeholder now: the fetched file doesn't replace it.
        for name in ["now a folder", "now a link", "already.txt"] {
            try CopyWriter.fetchFile(try Self.archive(Self.tarFile(name, "x")), id: Self.id, containerPath: "/x",
                                     to: tree.url("copy/" + name), stop: StopFlag())
        }
        let hosts = tree.url("copy/hosts"), parked = tree.url("outside/parked-hosts")
        try CopyWriter.fetchFile(try Self.archive(Self.tarFile("hosts", "overwritten")) {
            try? FileManager.default.moveItem(at: hosts, to: parked)
            FileManager.default.createFile(atPath: hosts.path, contents: nil, attributes: [.posixPermissions: 0])
        }, id: Self.id, containerPath: "/etc/hosts", to: hosts, stop: StopFlag())
        let modeAfterSwap = try FileManager.default.attributesOfItem(atPath: hosts.path)[.posixPermissions] as? Int
        #expect(modeAfterSwap == 0)
        #expect(tree.text("copy/already.txt") == "copy/already.txt")
        #expect(tree.snapshot() == ["copy/", "copy/already.txt", "copy/hosts", "copy/now a folder/", "copy/now a folder/inside.txt",
                                    "copy/now a link -> ../outside/secret.txt", "outside/", "outside/parked-hosts", "outside/secret.txt"])
        #expect(tree.text("outside/secret.txt") == "outside/secret.txt")
        #expect(TestTree.listing(of: tree.url("copy")).allSatisfy { !$0.hasPrefix(".strata-") })
    }

    // MARK: - Dragged out

    @Test func aDraggedOutItemNeverReplacesWhatsAtTheDrop() async throws {
        let tree = try TestTree("from/", "from/item/", "from/item/a.txt", "from/item/out -> /etc", "to/", "to/item/", "to/item/mine.txt")
        let source = tree.url("from/item")
        // The provider blocks until it's written, as on the drag's own queue: on a thread of its own here too.
        func write(to url: URL) async -> Error? {
            await withCheckedContinuation { done in
                DispatchQueue.global().async {
                    let item = ContainerDragItem(source: source, copies: .live)
                    ContainerPromises.shared.filePromiseProvider(item, writePromiseTo: url) { done.resume(returning: $0) }
                }
            }
        }
        // Where the receiving app asked for it, something is already there: it stays as it was.
        #expect(await write(to: tree.url("to/item")) != nil)
        #expect(await write(to: tree.url("to/fresh")) == nil)
        // Written fresh, a link that would lead out of what was copied is dropped.
        #expect(tree.snapshot() == ["from/", "from/item/", "from/item/a.txt", "from/item/out -> /etc", "to/", "to/fresh/", "to/fresh/a.txt",
                                    "to/item/", "to/item/mine.txt"])
    }
}

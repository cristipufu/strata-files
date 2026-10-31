import CryptoKit
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

struct ContainerTests {
    // MARK: HTTP over a Unix socket

    /// Serves one canned response on a fresh socket, returning its path and the request it received.
    static func serve(_ response: [UInt8]) throws -> (path: String, request: () -> String) {
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
        let received = Received()
        Thread.detachNewThread {
            let client = accept(server, nil, nil)
            // A client that stops reading early (as some of these tests do) must not kill the test run with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains(Data("\r\n\r\n".utf8)) {
                let count = recv(client, &buffer, buffer.count, 0)
                if count <= 0 { break }
                request.append(contentsOf: buffer[0..<count])
            }
            received.set(String(decoding: request, as: UTF8.self))
            _ = response.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            close(client)
            close(server)
            unlink(path)
        }
        return (path, received.get)
    }

    nonisolated final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func set(_ text: String) { lock.lock(); value = text; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func plainAndChunkedBodiesAreRead() throws {
        let plain = try Self.serve(Array("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8))
        let first = try UnixHTTP.send("GET", "/v1.41/_ping", to: plain.path)
        #expect(first.status == 200 && first.body == Data("hello".utf8))
        #expect(plain.request().hasPrefix("GET /v1.41/_ping HTTP/1.1\r\nHost: docker\r\n"))

        let chunked = try Self.serve(Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4;x=y\r\ndefg\r\n0\r\n\r\n".utf8))
        #expect(try UnixHTTP.send("GET", "/x", to: chunked.path).body == Data("abcdefg".utf8))
    }

    @Test func bodiesAreLimitedAndStreamsCanStopEarly() throws {
        let big = try Self.serve(Array("HTTP/1.1 200 OK\r\n\r\n".utf8) + [UInt8](repeating: 0x41, count: 10_000))
        #expect(throws: UnixHTTP.Failure.tooLarge) { try UnixHTTP.send("GET", "/x", to: big.path, limit: 1000) }

        let stream = try Self.serve(Array("HTTP/1.1 200 OK\r\n\r\n".utf8) + [UInt8](repeating: 0x42, count: 10_000))
        var seen = 0
        let head = try UnixHTTP.stream("GET", "/x", to: stream.path) { chunk in
            seen += chunk.count
            return false
        }
        #expect(head.status == 200 && seen > 0 && seen <= 10_000)
    }

    @Test func aLongIdleWaitIsFine() throws {
        // An event stream waits for a year; that must not overflow the per-read timeout.
        let server = try Self.serve(Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
        let response = try UnixHTTP.send("GET", "/events", to: server.path, idle: 365 * 24 * 3600)
        #expect(response.body == Data("ok".utf8))
    }

    @Test func malformedHeadsAreRefused() throws {
        #expect(throws: UnixHTTP.Failure.malformed) { try UnixHTTP.parseHead(Data("SMTP 220 hi".utf8)) }
        #expect(throws: UnixHTTP.Failure.malformed) { try UnixHTTP.parseHead(Data("HTTP/1.1 200 OK\r\nno colon".utf8)) }
        #expect(try UnixHTTP.parseHead(Data("HTTP/1.1 404 Not Found\r\nContent-Type: x".utf8)).headers["content-type"] == "x")
        #expect(queryEscaped("/my dir/a&b#c+é") == "/my%20dir/a%26b%23c%2B%C3%A9")
    }

    // MARK: Finding the engine

    @Test func enginesAreFoundLikeDockerFindsThem() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "strata-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".docker")
        let meta = config.appending(path: "contexts/meta/\(Self.sha256("colima"))")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try #"{"currentContext":"colima"}"#.write(to: config.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try #"{"Name":"colima","Endpoints":{"docker":{"Host":"unix:///Users/me/.colima/default/docker.sock"}}}"#
            .write(to: meta.appending(path: "meta.json"), atomically: true, encoding: .utf8)
        let list = EngineDiscovery.candidates(environment: ["DOCKER_HOST": "unix:///custom.sock"], home: home, temporary: home)
        #expect(list.first == "/custom.sock")
        #expect(list[1] == "/Users/me/.colima/default/docker.sock")
        #expect(list.contains(home.appending(path: ".orbstack/run/docker.sock").path))
        #expect(Set(list).count == list.count)
        // Remote engines aren't browsed.
        #expect(EngineDiscovery.socketPath(fromHost: "tcp://10.0.0.2:2376") == nil)
        #expect(EngineDiscovery.socketPath(fromHost: "ssh://me@box") == nil)
        #expect(EngineDiscovery.engineName(socket: "/x/.colima/default/docker.sock", operatingSystem: "Ubuntu 24.04") == "Colima")
        #expect(EngineDiscovery.engineName(socket: "/var/run/docker.sock", operatingSystem: "Docker Desktop") == "Docker Desktop")
        #expect(EngineDiscovery.isAPIVersion("1.41") && !EngineDiscovery.isAPIVersion("1.41/../x") && !EngineDiscovery.isAPIVersion("v1"))
        #expect(!EngineDiscovery.isUsableSocket(config.appending(path: "config.json").path))
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: The API's answers

    @Test func containersKeepOnlyWhatsShown() throws {
        let id = String(repeating: "ab", count: 32)
        let json = """
        [{"Id":"\(id)","Names":["/web"],"Image":"nginx:1.27","State":"running","Status":"Up 3 hours","Created":1700000000,
          "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web",
                    "com.docker.compose.project.working_dir":"/Users/me/shop","secret.token":"hunter2"},
          "Mounts":[{"Type":"bind","Source":"/Users/me/shop/html","Destination":"/usr/share/nginx/html","RW":false},
                    {"Type":"volume","Name":"shop_data","Source":"/var/lib/docker/volumes/shop_data/_data","Destination":"/data","RW":true},
                    {"Type":"bind","Source":"/x","Destination":"relative"}],
          "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}]},
         {"Id":"not-an-id","Names":["/bad"]},
         {"Id":"\(String(repeating: "cd", count: 32))","Names":["db\\u202e\\u0007"],"State":"exited"}]
        """
        let list = try ContainerAPI.parseContainers(Data(json.utf8))
        #expect(list.count == 2)
        let web = try #require(list.first)
        #expect(web.name == "web" && web.isRunning && web.image == "nginx:1.27")
        #expect(web.compose == ComposeLabels(project: "shop", service: "web", workingDirectory: "/Users/me/shop"))
        #expect(web.mounts.count == 2 && web.mounts[0].kind == .bind && !web.mounts[0].isWritable && web.mounts[1].name == "shop_data")
        #expect(web.ports.count == 2 && web.ports.allSatisfy { $0.containerPort == 80 && $0.hostPort == 8080 && $0.proto == "tcp" })
        // Control and direction-changing characters never reach the screen.
        #expect(list[1].name == "db" && list[1].state == .exited)
        #expect(ContainerAPI.isContainerID(web.id) && !ContainerAPI.isContainerID("../../etc") && !ContainerAPI.isContainerID(id.uppercased()))
    }

    @Test func execOutputIsDemultiplexed() throws {
        func frame(_ stream: UInt8, _ text: String) -> Data {
            let bytes = Array(text.utf8)
            return Data([stream, 0, 0, 0, UInt8(bytes.count >> 24), UInt8(bytes.count >> 16 & 0xFF), UInt8(bytes.count >> 8 & 0xFF), UInt8(bytes.count & 0xFF)] + bytes)
        }
        var demux = StreamDemux(outputLimit: 100, errorLimit: 4)
        let stream = frame(1, "hello ") + frame(2, "oops!!") + frame(1, "world")
        // Byte by byte, as a socket may deliver it.
        for byte in stream { _ = try demux.feed(Data([byte])) }
        #expect(String(decoding: demux.output, as: UTF8.self) == "hello world")
        #expect(String(decoding: demux.errors, as: UTF8.self) == "oops")
        var small = StreamDemux(outputLimit: 3, errorLimit: 0)
        #expect(throws: UnixHTTP.Failure.tooLarge) { try small.feed(frame(1, "toolong")) }
    }

    // MARK: Listings

    @Test func shellListingsKeepAnyName() {
        var data = Data()
        func add(_ header: String, _ name: String, _ target: String = "") {
            data.append(Data("\(header)\n".utf8)); data.append(Data(name.utf8)); data.append(0)
            data.append(Data(target.utf8)); data.append(0)
        }
        add("81a4 12 1700000000", "notes.txt")
        add("41ed 4096 1700000000", "with\nnewline and spaces")
        add("a1ff 7 1700000000", "localtime", "/usr/share/zoneinfo/UTC")
        add("21b6 0 1700000000", "null")
        let entries = ContainerListing.parseShell(data + Data("garbage".utf8))
        #expect(entries.map(\.name) == ["notes.txt", "with\nnewline and spaces", "localtime", "null"])
        // A container's own `stat` could print anything: the list ends at what isn't a whole number.
        var hostile = Data()
        for header in ["81a4 1 1700000000", "81a4 1 nan", "81a4 1 1e300"] {
            hostile.append(Data("\(header)\nx\0\0".utf8))
        }
        #expect(ContainerListing.parseShell(hostile).count == 1)
        #expect(ContainerTime.date(.infinity) == nil && ContainerTime.date(1e300) == nil && ContainerTime.seconds(nil) == 0)
        #expect(entries.map(\.kind) == [.file, .directory, .symlink, .other])
        #expect(entries[0].size == 12 && entries[0].mode == 0o644 && entries[1].size == 0)
        #expect(entries[2].linkTarget == "/usr/share/zoneinfo/UTC")
    }

    // MARK: Tar

    static func tarHeader(_ name: String, type: UInt8 = UInt8(ascii: "0"), size: Int = 0, link: String = "", mode: Int = 0o644) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ offset: Int, _ length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() { block[offset + index] = byte }
        }
        put(name, 0, 100)
        put(String(format: "%07o", mode), 100, 8)
        put(String(format: "%011o", size), 124, 12)
        put(String(format: "%011o", 1_700_000_000), 136, 12)
        block[156] = type
        put(link, 157, 100)
        put("ustar", 257, 6)
        for index in 148..<156 { block[index] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), 148, 6)
        block[154] = 0
        return block
    }

    static func tarFile(_ name: String, _ content: String) -> [UInt8] { tarFile(name, Array(content.utf8)) }

    static func tarFile(_ name: String, _ bytes: [UInt8]) -> [UInt8] {
        tarHeader(name, size: bytes.count) + bytes + [UInt8](repeating: 0, count: (512 - bytes.count % 512) % 512)
    }

    @Test func tarStreamsAreReadInAnyPieces() throws {
        let longName = "etc/" + String(repeating: "n", count: 150)
        let pax = "31 path=etc/pax-named-file.txt\n"
        var stream = Self.tarHeader("etc/", type: UInt8(ascii: "5"), mode: 0o755)
        stream += Self.tarFile("etc/hosts", "127.0.0.1 localhost\n")
        stream += Self.tarHeader("././@LongLink", type: UInt8(ascii: "L"), size: longName.utf8.count + 1)
            + Array(longName.utf8) + [0] + [UInt8](repeating: 0, count: 512 - (longName.utf8.count + 1) % 512)
        stream += Self.tarFile("ignored", "x")
        stream += Self.tarHeader("paxheader", type: UInt8(ascii: "x"), size: pax.utf8.count) + Array(pax.utf8)
            + [UInt8](repeating: 0, count: 512 - pax.utf8.count)
        stream += Self.tarFile("short", "pax!")
        stream += Self.tarHeader("etc/localtime", type: UInt8(ascii: "2"), link: "/usr/share/zoneinfo/UTC")
        stream += [UInt8](repeating: 0, count: 1024)
        for piece in [1, 7, 512, 100_000] {
            var reader = TarReader()
            var entries: [TarEntry] = []
            var data: [String: Data] = [:]
            var index = 0
            while index < stream.count {
                let end = min(index + piece, stream.count)
                try reader.feed(Data(stream[index..<end])) { event in
                    switch event {
                    case .begin(let entry): entries.append(entry)
                    case .data(let bytes): data[entries.last!.path, default: Data()].append(bytes)
                    case .end: break
                    }
                }
                index = end
            }
            #expect(reader.isFinished)
            #expect(entries.map(\.path) == ["etc", "etc/hosts", longName, "etc/pax-named-file.txt", "etc/localtime"], "pieces of \(piece)")
            #expect(entries.map(\.kind) == [.directory, .file, .file, .file, .symlink])
            #expect(data["etc/hosts"] == Data("127.0.0.1 localhost\n".utf8) && data["etc/pax-named-file.txt"] == Data("pax!".utf8))
            #expect(entries[4].linkTarget == "/usr/share/zoneinfo/UTC")
        }
        var bad = Self.tarHeader("x")
        bad[0] = 0x7A
        var reader = TarReader()
        #expect(throws: TarReader.Failure.malformed) { try reader.feed(Data(bad)) { _ in } }
        // Malformed PAX records and absurd sizes are refused, not trapped on.
        #expect(TarReader.paxRecords(Data("1 x=y\n".utf8)).isEmpty)
        #expect(TarReader.paxRecords(Data("999999999999999999 path=x\n".utf8)).isEmpty)
        var huge = Self.tarHeader("big", size: 0)
        let field = Array("77777777777".utf8)
        for (index, byte) in field.enumerated() { huge[124 + index] = byte }
        for index in 148..<156 { huge[index] = 0x20 }
        let sum = huge.reduce(0) { $0 + Int($1) }
        for (index, byte) in Array(String(format: "%06o", sum).utf8).enumerated() { huge[148 + index] = byte }
        huge[154] = 0
        var hugeReader = TarReader()
        // 8 GB fits (ustar's largest); it's read, not refused.
        try hugeReader.feed(Data(huge)) { _ in }
        // GNU base-256 sizes (files over 8 GB).
        #expect(TarReader.number([0x80, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0, 0][...]) == 1 << 33)
    }

    // MARK: Copies

    @Test func linksAlwaysResolveInsideTheCopy() {
        #expect(ContainerCopies.copyLinkTarget("/usr/share/zoneinfo/Etc/UTC", at: "/etc/localtime") == "../usr/share/zoneinfo/Etc/UTC")
        #expect(ContainerCopies.copyLinkTarget("usr/bin", at: "/bin") == "usr/bin")
        #expect(ContainerCopies.copyLinkTarget("../../../../etc/passwd", at: "/a/b/link") == "../../etc/passwd")
        #expect(ContainerCopies.copyLinkTarget("/", at: "/a/link") == "..")
        #expect(ContainerCopies.copyLinkTarget("/proc/mounts", at: "/etc/mtab") == "../proc/mounts")
        #expect(ContainerCopies.copyLinkTarget("", at: "/x") == nil)
        #expect(ContainerCopies.normalized("/a/./b/../../../c") == ["c"])
        for name in ["", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 256)] {
            #expect(!ContainerCopies.isSafeName(name), "\(name.debugDescription)")
        }
        #expect(ContainerCopies.isSafeName("..hidden") && ContainerCopies.isSafeName("name with spaces"))
        let top = URL(fileURLWithPath: "/tmp/copy/files")
        #expect(ContainerCopies.containerPath(of: top.appending(path: "etc/hosts"), top: top) == "/etc/hosts")
        #expect(ContainerCopies.containerPath(of: top, top: top) == "/")
        #expect(ContainerCopies.containerPath(of: URL(fileURLWithPath: "/tmp/copy/filesX"), top: top) == nil)
    }

    @Test func listingsAreWrittenWithoutEscapingTheFolder() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "strata-copy-\(UUID().uuidString)")
        let folder = base.appending(path: "files/etc")
        let outside = base.appending(path: "outside.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "keep me".write(to: outside, atomically: true, encoding: .utf8)
        // Planted before: a link where a file will be written, and an item the container no longer has.
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "hosts").path, withDestinationPath: outside.path)
        try "old".write(to: folder.appending(path: "gone.conf"), atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            ListedEntry(name: "hosts", kind: .file, size: 9, mode: 0o644, modified: date, linkTarget: ""),
            ListedEntry(name: "big.db", kind: .file, size: 5 << 20, mode: 0o600, modified: date, linkTarget: ""),
            ListedEntry(name: "small.conf", kind: .file, size: 10, mode: 0o4755, modified: date, linkTarget: ""),
            ListedEntry(name: "server", kind: .file, size: 50 << 20, mode: 0o755, modified: date, linkTarget: ""),
            ListedEntry(name: "apt", kind: .directory, size: 0, mode: 0o755, modified: date, linkTarget: ""),
            ListedEntry(name: "localtime", kind: .symlink, size: 0, mode: 0o777, modified: date, linkTarget: "/usr/share/zoneinfo/UTC"),
            ListedEntry(name: "../escape", kind: .file, size: 1, mode: 0o644, modified: date, linkTarget: ""),
            ListedEntry(name: "fifo", kind: .other, size: 0, mode: 0o644, modified: date, linkTarget: ""),
        ]
        let eager = try CopyWriter.apply(entries, contents: ["hosts": Data("127.0.0.1".utf8)], to: folder, containerPath: "/etc")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep me")
        #expect(try String(contentsOf: folder.appending(path: "hosts"), encoding: .utf8) == "127.0.0.1")
        let big = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "big.db").path)
        #expect((big[.size] as? Int) == 5 << 20 && (big[.posixPermissions] as? Int) == 0)
        // A program not fetched yet keeps only its execute bits: unreadable, but it shows as a Unix executable.
        let server = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "server").path)
        #expect((server[.posixPermissions] as? Int) == 0o111)
        #expect(ContainerCopies.isPlaceholderMode(0o111) && ContainerCopies.isPlaceholderMode(0) && !ContainerCopies.isPlaceholderMode(0o555))
        // Made executable in the container (same size and date): the placeholder follows.
        let plain = entries.map { $0.name == "server" ? ListedEntry(name: "server", kind: .file, size: 50 << 20, mode: 0o644, modified: date, linkTarget: "") : $0 }
        _ = try CopyWriter.apply(plain, contents: [:], to: folder, containerPath: "/etc")
        #expect((try FileManager.default.attributesOfItem(atPath: folder.appending(path: "server").path)[.posixPermissions] as? Int) == 0)
        #expect(eager.map(\.lastPathComponent) == ["small.conf"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: "localtime").path) == "../usr/share/zoneinfo/UTC")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "gone.conf").path))
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "files/escape").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "fifo").path))
        #expect(CopyWriter.readable(0o4755) == 0o555 && CopyWriter.readable(0o644) == 0o444 && CopyWriter.readable(0) == 0o400)
        // From another machine: marked as downloaded, so Gatekeeper checks what's opened (files, and folders that may be
        // apps).
        func quarantine(_ name: String) -> String? {
            var value = [UInt8](repeating: 0, count: 256)
            let count = getxattr(folder.appending(path: name).path, "com.apple.quarantine", &value, value.count, 0, XATTR_NOFOLLOW)
            return count > 0 ? String(decoding: value.prefix(count), as: UTF8.self) : nil
        }
        // The mark macOS gives a download by Strata: "downloaded", not "already approved", named Strata.
        let mark = String(decoding: CopyWriter.quarantine, as: UTF8.self)
        let flags = UInt32(mark.prefix(4), radix: 16) ?? 0
        #expect(flags & 0x0001 != 0 && flags & 0x0040 == 0 && mark.split(separator: ";")[2] == "Strata")
        #expect(quarantine("hosts") == mark && quarantine("apt") == mark)
        // Only its owner may read it: not fetched until it's opened.
        #expect(!CopyWriter.fetchesEagerly(size: 10, mode: 0o600, bytes: 0, count: 0))
        #expect(CopyWriter.fetchesEagerly(size: 10, mode: 0o644, bytes: 0, count: 0))
    }

    @Test func theContainersFolderFollowsTheEngine() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "strata-containers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "removed-one"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A store of its own, holding the folder as the app's holds each engine's.
        let copies = ContainerCopyStore(root: folder.deletingLastPathComponent())
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        func container(_ name: String, _ id: String, project: String? = nil) -> ContainerInfo {
            ContainerInfo(id: id, name: name, image: "nginx", state: .running, status: "Up", created: Date(timeIntervalSince1970: 1_700_000_000),
                          mounts: [], ports: [],
                          compose: project.map { ComposeLabels(project: $0, service: name, workingDirectory: nil) })
        }
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        let gone = try CopyWriter.syncContainers([container("web", first), container("../escape", second), container(".hidden", second)],
                                                 engine: engine, in: folder, copies: copies)
        #expect(gone.map(\.lastPathComponent) == ["removed-one"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["removed-one", "web"])
        let date = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "web").path)[.modificationDate] as? Date
        #expect(date == Date(timeIntervalSince1970: 1_700_000_000))
        // Made again under the same name: its folder starts over (the old one's files aren't this one's).
        let again = try CopyWriter.syncContainers([container("web", second)], engine: engine, in: folder, copies: copies)
        #expect(again.map(\.lastPathComponent).sorted() == ["removed-one", "web"])
    }

    @Test func composeProjectsGroupTheirContainers() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "strata-stacks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A store of its own, holding the folder as the app's holds each engine's.
        let copies = ContainerCopyStore(root: folder.deletingLastPathComponent())
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        func container(_ name: String, _ id: String, project: String? = nil) -> ContainerInfo {
            ContainerInfo(id: id, name: name, image: "nginx", state: .running, status: "Up", created: nil, mounts: [], ports: [],
                          compose: project.map { ComposeLabels(project: $0, service: name, workingDirectory: nil) })
        }
        let web = String(repeating: "a", count: 64), db = String(repeating: "b", count: 64), redis = String(repeating: "c", count: 64)
        // Where an older layout left it: beside the stacks. Grouping moves it and keeps what was already fetched.
        _ = try CopyWriter.syncContainers([container("web", web)], engine: engine, in: folder, copies: copies)
        try Data("notes".utf8).write(to: folder.appending(path: "web/readme.txt"))
        let gone = try CopyWriter.syncContainers(
            [container("web", web, project: "shop"), container("db", db, project: "shop"), container("redis", redis),
             container("odd", db, project: "../nope")],
            engine: engine, in: folder, copies: copies)
        #expect(gone.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["odd", "redis", "shop"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "shop").path).sorted() == ["db", "web"])
        #expect(try String(contentsOf: folder.appending(path: "shop/web/readme.txt"), encoding: .utf8) == "notes")
    }

    @Test func aLeftoverFolderNamedLikeAProjectMakesWay() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "strata-stacks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A store of its own, holding the folder as the app's holds each engine's.
        let copies = ContainerCopyStore(root: folder.deletingLastPathComponent())
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        func container(_ name: String, _ id: String, project: String? = nil) -> ContainerInfo {
            ContainerInfo(id: id, name: name, image: "nginx", state: .running, status: "Up", created: nil, mounts: [], ports: [],
                          compose: project.map { ComposeLabels(project: $0, service: name, workingDirectory: nil) })
        }
        let old = String(repeating: "a", count: 64), web = String(repeating: "b", count: 64), db = String(repeating: "c", count: 64)
        // A container called "shop", since removed, left its folder; now a project is called "shop".
        _ = try CopyWriter.syncContainers([container("shop", old)], engine: engine, in: folder, copies: copies)
        let list = [container("web", web, project: "shop"), container("db", db, project: "shop")]
        let gone = try CopyWriter.syncContainers(list, engine: engine, in: folder, copies: copies)
        #expect(gone.map(\.lastPathComponent) == ["shop"])
        // What discarding does; then the next pass makes the project's folder, its containers moved in.
        for url in gone { try FileManager.default.removeItem(at: url) }
        #expect(try CopyWriter.syncContainers(list, engine: engine, in: folder, copies: copies).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["shop"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "shop").path).sorted() == ["db", "web"])
    }

    @Test func projectsNamedAlikeShareAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "strata-stacks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A store of its own, holding the folder as the app's holds each engine's.
        let copies = ContainerCopyStore(root: folder.deletingLastPathComponent())
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        func container(_ name: String, _ id: String, project: String) -> ContainerInfo {
            ContainerInfo(id: id, name: name, image: "nginx", state: .running, status: "Up", created: nil, mounts: [], ports: [],
                          compose: ComposeLabels(project: project, service: name, workingDirectory: nil))
        }
        let list = [container("api", String(repeating: "a", count: 64), project: "App"),
                    container("worker", String(repeating: "b", count: 64), project: "app")]
        #expect(try CopyWriter.syncContainers(list, engine: engine, in: folder, copies: copies).isEmpty)
        let top = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        if tellsCaseApart(folder) {
            #expect(top == ["App", "app"])
        } else {
            // One folder on a disk that can't tell the names apart, with both projects' containers in it.
            #expect(top == ["App"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "App").path).sorted() == ["api", "worker"])
        }
    }

    @Test func aContainerCalledLikeAProjectKeepsItsFiles() throws {
        let engineFolder = FileManager.default.temporaryDirectory.appending(path: "strata-stacks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: engineFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: engineFolder) }
        // A store of its own, holding the folder as the app's holds each engine's.
        let copies = ContainerCopyStore(root: engineFolder.deletingLastPathComponent())
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        // A container on its own called "db", and a project called "db" too: the project's containers stay beside it,
        // never inside its files.
        let own = ContainerInfo(id: String(repeating: "a", count: 64), name: "db", image: "postgres", state: .running, status: "Up",
                                created: nil, mounts: [], ports: [], compose: nil)
        let member = ContainerInfo(id: String(repeating: "b", count: 64), name: "db-web-1", image: "nginx", state: .running,
                                   status: "Up", created: nil, mounts: [], ports: [],
                                   compose: ComposeLabels(project: "db", service: "web", workingDirectory: nil))
        _ = try CopyWriter.syncContainers([own, member], engine: engine, in: engineFolder, copies: copies)
        #expect(try copies.stackFolder(for: member, in: engineFolder).standardizedFileURL == engineFolder.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: engineFolder.appending(path: "db/db-web-1").path))
    }

    @Test func aProjectFolderMustBeAFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "strata-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Tool.app/Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "run.command")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        // Labels on a container (an image can set them) name the folder; Terminal would run a script it's handed.
        let asked = [root, script, root.appending(path: "Tool.app"), root.appending(path: "missing")]
        #expect(await StackProjects.existing(asked) == [root])
    }

    @Test func containerIconsFollowRunning() {
        #expect(ContainerIconMark.container(state: .running, busy: false) == .running)
        #expect(ContainerIconMark.container(state: .exited, busy: false) == .stopped)
        #expect(ContainerIconMark.container(state: .paused, busy: false) == .changing)
        #expect(ContainerIconMark.container(state: .running, busy: true) == .changing)
        #expect(ContainerIconMark.stack(states: [.running, .running], anyBusy: false) == .running)
        #expect(ContainerIconMark.stack(states: [.exited], anyBusy: false) == .stopped)
        #expect(ContainerIconMark.stack(states: [.running, .exited], anyBusy: false) == .changing)
        #expect(ContainerIconMark.stack(states: [], anyBusy: false) == .stopped)
        #expect(ContainerIconMark.running.containerSymbol == "shippingbox.fill")
        #expect(ContainerIconMark.stopped.containerSymbol == "shippingbox")
        #expect(ContainerIconMark.running.stackSymbol == "square.stack.3d.up.fill")
        #expect(ContainerIconMark.stopped.stackSymbol == "square.stack.3d.up")
    }

    @Test func projectEditorsAreCodeEditors() {
        #expect(ProjectEditors.includes(bundleID: "com.todesktop.230313mzl4w4u92", category: nil))
        #expect(ProjectEditors.includes(bundleID: "com.microsoft.VSCode", category: nil))
        #expect(ProjectEditors.includes(bundleID: "com.sublimetext.4", category: nil))
        #expect(ProjectEditors.includes(bundleID: "com.jetbrains.pycharm.ce", category: nil))
        #expect(ProjectEditors.includes(bundleID: "com.google.antigravity-ide", category: "public.app-category.developer-tools"))
        #expect(!ProjectEditors.includes(bundleID: "com.apple.TextEdit", category: "public.app-category.productivity"))
        #expect(!ProjectEditors.includes(bundleID: "com.microsoft.Word", category: nil))
        #expect(!ProjectEditors.includes(bundleID: "com.anthropic.claudefordesktop", category: "public.app-category.developer-tools"))
        #expect(!ProjectEditors.includes(bundleID: "com.apple.dt.Instruments", category: "public.app-category.developer-tools"))
    }

    @Test func actionsAreOnePostEach() throws {
        let id = String(repeating: "c", count: 64)
        let engine = { (path: String) in ContainerEngine(socket: path, name: "Docker", apiVersion: "1.41") }
        let ok = try Self.serve(Array("HTTP/1.1 204 No Content\r\n\r\n".utf8))
        try ContainerAPI.perform(.stop, engine(ok.path), id: id)
        #expect(ok.request().hasPrefix("POST /v1.41/containers/\(id)/stop?t=10 HTTP/1.1\r\n"))
        #expect(ok.request().contains("Content-Length: 0\r\n"))
        let body = #"{"message":"port is already allocated: 5432"}"#
        let refused = try Self.serve(Array("HTTP/1.1 500 Internal Server Error\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        #expect(throws: ContainerAPIError.status(500, "port is already allocated: 5432")) { try ContainerAPI.perform(.start, engine(refused.path), id: id) }
        #expect(throws: ContainerAPIError.notFound) { try ContainerAPI.perform(.start, engine("/nonexistent"), id: "../../x") }
        #expect(ContainerAction.start.applies(to: .exited) && !ContainerAction.start.applies(to: .running))
        #expect(ContainerAction.unpause.applies(to: .paused) && !ContainerAction.pause.applies(to: .paused))
    }

    @Test func theTerminalScriptQuotesEverything() async throws {
        let bin = FileManager.default.temporaryDirectory.appending(path: "strata-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        func executable(_ name: String, _ body: String) throws {
            let url = bin.appending(path: name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // A fake `docker` that prints DOCKER_HOST, then each argument on its own line.
        try executable("docker", "#!/bin/sh\nprintf 'HOST=%s\\n' \"$DOCKER_HOST\"\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n")
        // The login shell is only asked for its PATH (whatever shell it is): this one's has our folder first, and it
        // chats before and after, as login shells do.
        try executable("login", "#!/bin/sh\necho 'Last login: today'\nPATH='\(bin.path):/usr/bin:/bin'; export PATH\n/bin/sh -c \"$4\"\necho bye\n")
        let id = String(repeating: "d", count: 64)
        let path = "/srv/it's $(touch pwned) `id` \"x\" \\'; end; touch pwned2 #"
        let socket = "/Users/me/odd 'socket'.sock"
        let script = bin.appending(path: "t.command")
        try ContainerControl.terminalScript(id: id, path: path, socket: socket).write(to: script, atomically: true, encoding: .utf8)
        let (status, output) = try await withCheckedThrowingContinuation { (done: CheckedContinuation<(Int32, Data), Error>) in
            DispatchQueue.global().async {
                done.resume(with: Result {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = [script.path]
                    process.environment = ["PATH": "/usr/bin:/bin", "SHELL": bin.appending(path: "login").path, "HOME": bin.path]
                    process.currentDirectoryURL = bin
                    process.standardInput = FileHandle.nullDevice
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    defer { if process.isRunning { process.terminate() } }
                    // Drain output before waiting for exit, and keep both waits off the main actor.
                    let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()
                    return (process.terminationStatus, output)
                })
            }
        }
        #expect(status == 0)
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.prefix(8) == ["HOST=unix://" + socket, "exec", "-it", "-w", path, id, "/bin/sh", "-c"])
        #expect(!FileManager.default.fileExists(atPath: bin.appending(path: "pwned").path))
        #expect(!FileManager.default.fileExists(atPath: bin.appending(path: "pwned2").path))
        #expect(!FileManager.default.fileExists(atPath: script.path), "the script deletes itself")
    }

    @Test func terminalFileNamesArePlainASCII() {
        // Ghostty garbles anything else in the path of a .command file it runs.
        #expect(ProjectActions.sanitize("shop-db — Terminal") == "shop-db - Terminal")
        #expect(ProjectActions.sanitize("Café — npm run dev") == "Cafe - npm run dev")
        #expect(ProjectActions.sanitize("../../etc — passwd") == "etc - passwd")
        #expect(ProjectActions.sanitize("日本語") == "Strata")
        #expect(ProjectActions.sanitize("a/b:c") == "a-b-c")
    }

    @Test func namesTheDiskCantTellApartKeepTheFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "strata-case-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard !tellsCaseApart(folder) else { return }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            ListedEntry(name: "README", kind: .file, size: 5, mode: 0o644, modified: date, linkTarget: ""),
            ListedEntry(name: "readme", kind: .file, size: 7, mode: 0o644, modified: date, linkTarget: ""),
        ]
        _ = try CopyWriter.apply(entries, contents: ["README": Data("upper".utf8), "readme": Data("lowerrr".utf8)], to: folder, containerPath: "/")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["README"])
        #expect(try String(contentsOf: folder.appending(path: "README"), encoding: .utf8) == "upper")
        // Listed again, the same way: nothing is removed.
        _ = try CopyWriter.apply(entries, contents: [:], to: folder, containerPath: "/")
        #expect(try String(contentsOf: folder.appending(path: "README"), encoding: .utf8) == "upper")
    }

    @Test func aCopyOnADiskThatTellsCaseApartKeepsBothNames() async throws {
        // Names fold by the disk a copy is on, not by the disk of the app's own copies.
        let volume = try await ScratchVolume.make(fileSystem: "Case-sensitive APFS")
        let folder = volume.url("copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(tellsCaseApart(folder))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            ListedEntry(name: "README", kind: .file, size: 5, mode: 0o644, modified: date, linkTarget: ""),
            ListedEntry(name: "readme", kind: .file, size: 7, mode: 0o644, modified: date, linkTarget: ""),
        ]
        _ = try CopyWriter.apply(entries, contents: ["README": Data("upper".utf8), "readme": Data("lowerrr".utf8)], to: folder, containerPath: "/")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["README", "readme"])
        // Listed again with one gone: only that one goes.
        _ = try CopyWriter.apply([entries[0]], contents: [:], to: folder, containerPath: "/")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["README"])
        #expect(try String(contentsOf: folder.appending(path: "README"), encoding: .utf8) == "upper")
        // Projects whose names differ only in case get a folder each there.
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        let engineFolder = volume.url("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: engineFolder, withIntermediateDirectories: false)
        let copies = ContainerCopyStore(root: volume.root)
        let list = [ContainerInfo(id: String(repeating: "a", count: 64), name: "api", image: "nginx", state: .running, status: "Up",
                                  created: nil, mounts: [], ports: [], compose: ComposeLabels(project: "App", service: "api", workingDirectory: nil)),
                    ContainerInfo(id: String(repeating: "b", count: 64), name: "worker", image: "nginx", state: .running, status: "Up",
                                  created: nil, mounts: [], ports: [], compose: ComposeLabels(project: "app", service: "worker", workingDirectory: nil))]
        #expect(try CopyWriter.syncContainers(list, engine: engine, in: engineFolder, copies: copies).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: engineFolder.path).sorted() == ["App", "app"])
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.removeItem(at: engineFolder)
        await volume.eject()
    }
}


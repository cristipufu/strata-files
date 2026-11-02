import Darwin
import Foundation
import StrataModel
import StrataSupport

/// A small HTTP/1.1 client over a Unix domain socket, for a container engine's API (Docker's, and the engines that
/// speak it: OrbStack, Colima, Podman, Rancher Desktop). Blocking: call it off the main thread.
///
/// It only ever talks to a socket file on this Mac, never the network. Every read waits at most `idle` seconds, a
/// response body is capped, and `shouldStop` is checked between reads, so a stuck or chatty engine can't hang Strata.
package nonisolated enum UnixHTTP {
    package struct Head: Sendable, Equatable {
        package let status: Int
        /// Header names in lower case.
        package let headers: [String: String]
    }

    package struct Response: Sendable {
        package let head: Head
        package let body: Data
        package var status: Int { head.status }
    }

    package enum Failure: Error, Equatable {
        case pathTooLong
        case connect(Int32)
        case send
        case timeout
        case closed
        case tooLarge
        case malformed
        case stopped
    }

    /// The longest head (status line and headers) accepted.
    package static let headLimit = 64 * 1024

    /// Sends a request and returns the whole response; bodies over `limit` bytes fail with `.tooLarge`.
    package static func send(_ method: String, _ target: String, to socket: String, json: Data? = nil, idle: TimeInterval = 10,
                     total: TimeInterval? = nil, limit: Int = 32 << 20) throws -> Response {
        var body = Data()
        let head = try stream(method, target, to: socket, json: json, idle: idle, total: total) { chunk in
            guard body.count + chunk.count <= limit else { throw Failure.tooLarge }
            body.append(chunk)
            return true
        }
        return Response(head: head, body: body)
    }

    /// Sends a request and hands the body to `receive` as it arrives (chunked encoding removed). `onHead` sees the status
    /// and headers before any of the body. `receive` returns false to stop early, which closes the connection.
    /// `shouldStop` is polled at least every second while waiting; `total` caps the whole exchange.
    @discardableResult
    package static func stream(_ method: String, _ target: String, to socket: String, json: Data? = nil, idle: TimeInterval = 10,
                       total: TimeInterval? = nil, shouldStop: @escaping () -> Bool = { false },
                       onHead: (Head) throws -> Void = { _ in }, receive: (Data) throws -> Bool) throws -> Head {
        let connection = try Connection(socket: socket, idle: idle, total: total, shouldStop: shouldStop)
        defer { connection.close() }
        try connection.write(request(method, target, json: json))
        let head = try connection.readHead()
        try onHead(head)
        if method == "HEAD" || head.status == 204 || head.status == 304 || (100..<200).contains(head.status) { return head }
        do {
            if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                try connection.readChunked(receive)
            } else if let length = head.headers["content-length"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                guard length >= 0 else { throw Failure.malformed }
                try connection.readExactly(length, receive)
            } else {
                try connection.readToEnd(receive)
            }
        } catch is EnoughRead {
            // `receive` had what it wanted.
        }
        return head
    }

    /// The request's bytes. `target` is an origin-form path with its query, already percent-encoded.
    package static func request(_ method: String, _ target: String, json: Data?) -> Data {
        var text = "\(method) \(target) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Strata\r\nAccept: */*\r\nConnection: close\r\n"
        if let json {
            text += "Content-Type: application/json\r\nContent-Length: \(json.count)\r\n"
        } else if method == "POST" {
            text += "Content-Length: 0\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if let json { data.append(json) }
        return data
    }

    /// Parses a response head (without the blank line that ends it).
    package static func parseHead(_ data: Data) throws -> Head {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw Failure.malformed }
        let lines = text.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]), (100...599).contains(code) else {
            throw Failure.malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Head(status: code, headers: headers)
    }

    /// Thrown inside when `receive` asks to stop; `stream` returns normally.
    private struct EnoughRead: Error {}

    /// One connection: a socket with a read buffer.
    private final class Connection {
        private var fd: Int32
        private let idle: TimeInterval
        private let end: Date?
        private let shouldStop: () -> Bool
        private var buffer = Data()

        init(socket path: String, idle: TimeInterval, total: TimeInterval?, shouldStop: @escaping () -> Bool) throws {
            self.idle = idle
            self.end = total.map { Date().addingTimeInterval($0) }
            self.shouldStop = shouldStop
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count < capacity else { throw Failure.pathTooLong }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.connect(errno) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else {
                let error = errno
                Darwin.close(fd)
                fd = -1
                throw Failure.connect(error)
            }
        }

        func close() {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }

        func write(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let sent = Darwin.send(fd, base + offset, raw.count - offset, 0)
                    if sent < 0, errno == EINTR { continue }
                    guard sent > 0 else { throw Failure.send }
                    offset += sent
                }
            }
        }

        /// Reads more into the buffer; false at the end of the stream.
        private func fill() throws -> Bool {
            let deadline = min(Date().addingTimeInterval(idle), end ?? .distantFuture)
            while true {
                if shouldStop() { throw Failure.stopped }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                // Clamped while still a Double: a long idle (an event stream's) doesn't fit in an Int32.
                let wait = Int32(max(0, min(1000, deadline.timeIntervalSinceNow * 1000)))
                let ready = poll(&poller, 1, wait)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw Failure.closed
                }
                if ready == 0 {
                    if Date() >= deadline { throw Failure.timeout }
                    continue
                }
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = recv(fd, &chunk, chunk.count, 0)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw Failure.closed
                }
                if count == 0 { return false }
                buffer.append(contentsOf: chunk[0..<count])
                return true
            }
        }

        func readHead() throws -> Head {
            let separator = Data("\r\n\r\n".utf8)
            while true {
                if let range = buffer.range(of: separator) {
                    let head = try UnixHTTP.parseHead(buffer[buffer.startIndex..<range.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    return head
                }
                guard buffer.count <= UnixHTTP.headLimit else { throw Failure.malformed }
                guard try fill() else { throw Failure.closed }
            }
        }

        /// A line ending in CRLF (without it), for chunk sizes and trailers.
        private func readLine() throws -> String {
            let crlf = Data("\r\n".utf8)
            while true {
                if let range = buffer.range(of: crlf) {
                    let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    return line
                }
                guard buffer.count <= 4096 else { throw Failure.malformed }
                guard try fill() else { throw Failure.closed }
            }
        }

        func readExactly(_ count: Int, _ receive: (Data) throws -> Bool) throws {
            var left = count
            while left > 0 {
                if buffer.isEmpty { guard try fill() else { throw Failure.closed } }
                let take = min(left, buffer.count)
                let piece = Data(buffer.prefix(take))
                buffer.removeFirst(take)
                left -= take
                guard try receive(piece) else { throw EnoughRead() }
            }
        }

        func readChunked(_ receive: (Data) throws -> Bool) throws {
            while true {
                let line = try readLine()
                let digits = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !digits.isEmpty, digits.count <= 15, let size = Int(digits, radix: 16), size >= 0 else { throw Failure.malformed }
                if size == 0 {
                    // Trailers, then the empty line.
                    while try !readLine().isEmpty {}
                    return
                }
                try readExactly(size, receive)
                guard try readLine().isEmpty else { throw Failure.malformed }
            }
        }

        func readToEnd(_ receive: (Data) throws -> Bool) throws {
            while true {
                if !buffer.isEmpty {
                    let piece = buffer
                    buffer.removeAll(keepingCapacity: true)
                    guard try receive(piece) else { throw EnoughRead() }
                }
                guard try fill() else { return }
            }
        }
    }
}

/// Percent-encodes a query value (a path inside a container: spaces, `&`, `#`, `+` and non-ASCII all escaped).
package nonisolated func queryEscaped(_ value: String) -> String {
    // ASCII only: `alphanumerics` would let other scripts' letters through unescaped.
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

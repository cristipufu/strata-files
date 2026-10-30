import CryptoKit
import Foundation

nonisolated struct S3Credentials: Sendable, Equatable {
    var accessKeyID: String
    var secretAccessKey: String
    /// For temporary credentials.
    var sessionToken: String?
}

/// A key in a bucket listing: an object, or a "folder" (a common prefix ending in "/").
nonisolated struct S3Item: Sendable, Equatable {
    let key: String
    let size: Int64
    let modified: Date?
    let isFolder: Bool
}

nonisolated enum S3Error: Error, Equatable, LocalizedError {
    /// The service said no: its error code (AccessDenied, NoSuchKey, SignatureDoesNotMatch…) and message.
    case service(status: Int, code: String, message: String)
    case badResponse
    case tooLarge
    case insecure
    /// More came than was listed (the object changed, or the service won't stop).
    case changed

    var errorDescription: String? {
        switch self {
        case .service(let status, let code, let message):
            switch code {
            case "AccessDenied": String(localized: "The bucket doesn’t allow that with this access key.")
            case "NoSuchKey": String(localized: "It isn’t in the bucket anymore.")
            case "NoSuchBucket": String(localized: "There’s no such bucket at this address.")
            case "SignatureDoesNotMatch", "InvalidAccessKeyId": String(localized: "The access key or its secret isn’t right.")
            default: message.isEmpty ? String(localized: "The storage service answered \(status) (\(code)).", comment: "An HTTP status and an error code")
                : String(message.prefix(300))
            }
        case .badResponse: String(localized: "The storage service sent something Strata doesn’t understand.")
        case .tooLarge: String(localized: "Files over 5 GB can’t be uploaded to a bucket yet.")
        case .insecure: String(localized: "Strata only sends credentials over a secure (https) connection.")
        case .changed: String(localized: "It changed in the bucket while it was being read. Reload the folder and try again.")
        }
    }
}

/// AWS Signature Version 4 for S3: what every request carries. Pure, so it's checked against AWS's own examples.
nonisolated enum S3Signer {
    static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// Every character but the unreserved ones percent-encoded (and "/" too, unless `keepSlash`), as SigV4 wants.
    static func encode(_ text: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The headers to add: x-amz-date, x-amz-content-sha256, the session token if any, and Authorization. `path` is
    /// already encoded; `query` pairs aren't.
    static func sign(method: String, host: String, path: String, query: [(String, String)], headers: [String: String],
                     payloadHash: String, credentials: S3Credentials, region: String, date: Date) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let day = String(amzDate.prefix(8))

        var signed = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.trimmingCharacters(in: .whitespaces) }
        signed["host"] = host
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash
        if let token = credentials.sessionToken { signed["x-amz-security-token"] = token }
        let names = signed.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(signed[$0] ?? "")\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let encodedQuery: [(name: String, value: String)] = query.map { pair in
            (encode(pair.0, keepSlash: false), encode(pair.1, keepSlash: false))
        }
        let sortedQuery = encodedQuery.sorted { a, b in a.name != b.name ? a.name < b.name : a.value < b.value }
        let canonicalQuery = sortedQuery.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        func hmac(_ key: Data, _ message: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
        }
        let signingKey = hmac(hmac(hmac(hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), day), region), "s3"), "aws4_request")
        let signature = hmac(signingKey, stringToSign).map { String(format: "%02x", $0) }.joined()

        var result = ["x-amz-date": amzDate, "x-amz-content-sha256": payloadHash,
                      "Authorization": "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"]
        if let token = credentials.sessionToken { result["x-amz-security-token"] = token }
        return result
    }

    static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One bucket on AWS S3 or an S3-compatible service, spoken to directly (HTTPS, SigV4). Keys are paths without a
/// leading "/"; a folder is a key prefix ending in "/".
nonisolated final class S3Client: Sendable {
    let host: String
    let port: Int?
    let bucket: String
    let region: String
    let pathStyle: Bool
    private let credentials: S3Credentials
    private let session: URLSession

    /// Pages of a listing at most (a thousand keys each).
    static let maxPages = 20_000
    /// An answer other than a download is read up to this much.
    static let maxBody = 32 << 20

    /// Plain http only reaches a server on this Mac (a local MinIO); anywhere else, credentials go over https.
    /// `configuration`: tests answer requests themselves.
    init(host: String, port: Int? = nil, bucket: String, region: String, pathStyle: Bool, credentials: S3Credentials,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.host = host
        self.port = port
        self.bucket = bucket
        self.region = region
        // A bucket name with dots doesn't fit the endpoint's certificate as a subdomain.
        self.pathStyle = pathStyle || bucket.contains(".")
        self.credentials = credentials
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private var isLocal: Bool { ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) }

    // MARK: - Requests

    private func request(_ method: String, key: String = "", query: [(String, String)] = [], headers: [String: String] = [:],
                         payloadHash: String = S3Signer.emptyHash) throws -> URLRequest {
        let scheme = isLocal ? "http" : "https"
        let authority = (pathStyle ? host : "\(bucket).\(host)") + (port.map { ":\($0)" } ?? "")
        let path = (pathStyle ? "/\(bucket)/" : "/") + S3Signer.encode(key, keepSlash: true)
        var text = "\(scheme)://\(authority)\(path)"
        if !query.isEmpty {
            text += "?" + query.map { "\(S3Signer.encode($0.0, keepSlash: false))=\(S3Signer.encode($0.1, keepSlash: false))" }.joined(separator: "&")
        }
        guard let url = URL(string: text), url.scheme == "https" || isLocal else { throw S3Error.insecure }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let signedHost = pathStyle ? host + (port.map { ":\($0)" } ?? "") : authority
        let signature = S3Signer.sign(method: method, host: signedHost, path: path, query: query, headers: headers,
                                      payloadHash: payloadHash, credentials: credentials, region: region, date: Date())
        for (name, value) in headers.merging(signature, uniquingKeysWith: { _, new in new }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Throws the service's error for a failed response.
    private static func check(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw S3Error.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = S3ErrorParser.parse(body)
            throw S3Error.service(status: http.statusCode, code: parsed.code.isEmpty ? "HTTP\(http.statusCode)" : parsed.code, message: parsed.message)
        }
    }

    /// A request's answer, read up to `maxBody` (a service that won't stop talking is cut off, not held in memory).
    @concurrent private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(Self.maxBody) { throw S3Error.tooLarge }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > Self.maxBody { throw S3Error.tooLarge }
        }
        return (body, response)
    }

    // MARK: - Operations

    /// What's directly inside `prefix` ("" for the top, else ending in "/"): its folders and objects.
    @concurrent func list(_ prefix: String) async throws -> [S3Item] {
        // The folder's own marker object ("photos/" inside "photos/") isn't an item of it.
        try await pages(prefix, delimiter: true).filter { $0.key != prefix }
    }

    /// Every object under `prefix`, at any depth (to copy, rename or delete a folder).
    @concurrent func listAll(_ prefix: String) async throws -> [S3Item] {
        try await pages(prefix, delimiter: false)
    }

    /// A listing, page after page. A service repeating a continuation token, or saying there's more while sending
    /// nothing, is stopped rather than followed forever; so is one past a million keys.
    @concurrent private func pages(_ prefix: String, delimiter: Bool) async throws -> [S3Item] {
        var items: [S3Item] = []
        var token: String?
        var seen: Set<String> = []
        var count = 0
        repeat {
            try Task.checkCancellation()
            var query = [("list-type", "2"), ("prefix", prefix)]
            if delimiter { query.append(("delimiter", "/")) }
            if let token { query.append(("continuation-token", token)) }
            let (body, response) = try await send(request("GET", query: query))
            try Self.check(response, body)
            let page = S3ListParser.parse(body)
            guard page.valid else { throw S3Error.badResponse }
            items += page.items
            count += 1
            token = page.truncated ? page.nextToken : nil
            if let next = token, page.items.isEmpty || !seen.insert(next).inserted || next.isEmpty { throw S3Error.badResponse }
            if items.count > 1_000_000 || count > Self.maxPages { throw S3Error.badResponse }
        } while token != nil
        return items
    }

    @concurrent func head(_ key: String) async throws -> S3Item? {
        let (body, response) = try await send(request("HEAD", key: key))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.check(response, body)
        guard let http = response as? HTTPURLResponse else { throw S3Error.badResponse }
        let size = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        let modified = http.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
        return S3Item(key: key, size: size, modified: modified, isFolder: false)
    }

    /// The object at `key` into `destination` (replaced): at most `limit` bytes (the size it was listed with); `stop`
    /// ends it between chunks, as does cancelling the task.
    @concurrent func download(_ key: String, to destination: URL, limit: Int64 = .max, progress: @escaping @Sendable (Int64) -> Void = { _ in },
                  stop: StopFlag = StopFlag()) async throws {
        let (bytes, response) = try await session.bytes(for: request("GET", key: key))
        guard let http = response as? HTTPURLResponse else { throw S3Error.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes.prefix(64 * 1024) { body.append(byte) }
            try Self.check(response, body)
            return
        }
        if http.expectedContentLength > limit { throw S3Error.changed }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let file = try? FileHandle(forWritingTo: destination) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? file.close() }
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        var total: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            let (currentTotal, overflow) = total.addingReportingOverflow(Int64(buffer.count))
            if overflow || currentTotal > limit { throw S3Error.changed }
            if buffer.count >= 256 * 1024 {
                try Task.checkCancellation()
                if stop.isSet { throw CancellationError() }
                try file.write(contentsOf: buffer)
                total += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(total)
            }
        }
        try file.write(contentsOf: buffer)
        progress(total + Int64(buffer.count))
    }

    /// The local file at `source` to `key` (replacing what's there). Up to 5 GB. `progress` gets the bytes sent.
    @concurrent func upload(_ source: URL, to key: String, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 5 << 30 else { throw S3Error.tooLarge }
        var request = try request("PUT", key: key, headers: ["Content-Length": String(size)], payloadHash: S3Signer.unsignedPayload)
        request.timeoutInterval = 3600
        let (body, response) = try await session.upload(for: request, fromFile: source, delegate: UploadProgress(progress))
        try Self.check(response, body.prefix(Self.maxBody))
    }

    /// An empty "folder/" marker, so a new folder shows before anything is in it.
    @concurrent func makeFolder(_ prefix: String) async throws {
        let (body, response) = try await session.upload(for: request("PUT", key: prefix, headers: ["Content-Length": "0"]), from: Data())
        try Self.check(response, body.prefix(Self.maxBody))
    }

    /// A server-side copy (no download), up to 5 GB.
    @concurrent func copy(_ key: String, to newKey: String) async throws {
        let source = "/" + bucket + "/" + S3Signer.encode(key, keepSlash: true)
        let (body, response) = try await send(request("PUT", key: newKey, headers: ["x-amz-copy-source": source]))
        try Self.check(response, body)
        // A copy can fail after the 200 has started (the error is in the body): it only counts with its result.
        guard body.range(of: Data("<CopyObjectResult".utf8)) != nil, S3ErrorParser.parse(body).code.isEmpty else { throw S3Error.badResponse }
    }

    @concurrent func delete(_ key: String) async throws {
        guard !key.isEmpty else { throw S3Error.badResponse }
        let (body, response) = try await send(request("DELETE", key: key))
        try Self.check(response, body)
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// Requests are signed for one host: a redirect would send them (and their credentials) somewhere else, so none is
/// followed; the service's answer stands (an error, say, for the wrong region).
nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Bytes sent so far, for an upload's progress.
nonisolated private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - XML

/// S3 never sends a DTD: one that does could expand entities without end, so it isn't parsed at all. Nor anything but
/// UTF-8 (a NUL byte means UTF-16 or worse, where the check above wouldn't see the declaration).
nonisolated private func declaresDocumentType(_ data: Data) -> Bool {
    data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil || data.contains(0)
}

/// ListObjectsV2's answer. Foundation's parser doesn't fetch external entities, and the answer is size-checked first.
nonisolated final class S3ListParser: NSObject, XMLParserDelegate {
    var items: [S3Item] = []
    var truncated = false
    var nextToken: String?
    var valid = false
    private var path: [String] = []
    private var text = ""
    private var key = "", size: Int64 = 0, modified: Date?

    static func parse(_ data: Data) -> S3ListParser {
        let delegate = S3ListParser()
        guard data.count <= 64 << 20, !declaresDocumentType(data) else { return delegate }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        delegate.valid = parser.parse() && delegate.sawRoot
        return delegate
    }

    private var sawRoot = false
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoWhole = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
        if name == "ListBucketResult" { sawRoot = true }
        if name == "Contents" || name == "CommonPrefixes" { key = ""; size = 0; modified = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 4096 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        switch (parent, name) {
        case ("Contents", "Key"), ("CommonPrefixes", "Prefix"): key = text
        // Never negative or absurd, whatever the service says (sums of sizes mustn't overflow).
        case ("Contents", "Size"): size = min(max(Int64(text) ?? 0, 0), 1 << 44)
        case ("Contents", "LastModified"): modified = iso.date(from: text) ?? isoWhole.date(from: text)
        case ("ListBucketResult", "IsTruncated"): truncated = text == "true"
        case ("ListBucketResult", "NextContinuationToken"): nextToken = text
        case (_, "Contents"): if !key.isEmpty { items.append(S3Item(key: key, size: size, modified: modified, isFolder: false)) }
        case (_, "CommonPrefixes"): if !key.isEmpty { items.append(S3Item(key: key, size: 0, modified: nil, isFolder: true)) }
        default: break
        }
        if !path.isEmpty { path.removeLast() }
        text = ""
    }
}

/// `<Error><Code>…</Code><Message>…</Message></Error>`.
nonisolated final class S3ErrorParser: NSObject, XMLParserDelegate {
    var code = ""
    var message = ""
    private var current = ""
    private var text = ""

    static func parse(_ data: Data) -> S3ErrorParser {
        let delegate = S3ErrorParser()
        guard !data.isEmpty, data.count <= 1 << 20, !declaresDocumentType(data) else { return delegate }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        current = name
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 1000 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "Code" { code = text }
        if name == "Message" { message = text }
    }
}

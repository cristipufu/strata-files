import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// Signature Version 4, checked against the examples in AWS's S3 documentation ("Signature Calculations for the
/// Authorization Header: Transferring Payload in a Single Chunk"), which use AWS's published example key.
// One at a time: they share `FakeS3`'s answer.
@Suite(.serialized)
struct S3Tests {
    let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
    let host = "examplebucket.s3.amazonaws.com"

    private func signature(_ headers: [String: String]) -> String? {
        headers["Authorization"]?.components(separatedBy: "Signature=").last
    }

    @Test func getObject() {
        let headers = S3Signer.sign(method: "GET", host: host, path: "/test.txt", query: [], headers: ["Range": "bytes=0-9"],
                                    payloadHash: S3Signer.emptyHash, credentials: credentials, region: "us-east-1", date: date)
        #expect(signature(headers) == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        #expect(headers["Authorization"]?.contains("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date") == true)
        #expect(headers["x-amz-date"] == "20130524T000000Z")
    }

    @Test func putObject() {
        let path = "/" + S3Signer.encode("test$file.text", keepSlash: true)
        #expect(path == "/test%24file.text")
        let headers = S3Signer.sign(method: "PUT", host: host, path: path, query: [],
                                    headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
                                    payloadHash: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
                                    credentials: credentials, region: "us-east-1", date: date)
        #expect(signature(headers) == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test func getBucketLifecycle() {
        let headers = S3Signer.sign(method: "GET", host: host, path: "/", query: [("lifecycle", "")], headers: [:],
                                    payloadHash: S3Signer.emptyHash, credentials: credentials, region: "us-east-1", date: date)
        #expect(signature(headers) == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    @Test func listObjects() {
        // Query pairs are sorted for signing whatever order they're given in.
        let headers = S3Signer.sign(method: "GET", host: host, path: "/", query: [("prefix", "J"), ("max-keys", "2")], headers: [:],
                                    payloadHash: S3Signer.emptyHash, credentials: credentials, region: "us-east-1", date: date)
        #expect(signature(headers) == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func encodingKeepsOnlyUnreservedCharacters() {
        #expect(S3Signer.encode("photos/2026 trip/ä+b=c&d.jpg", keepSlash: true) == "photos/2026%20trip/%C3%A4%2Bb%3Dc%26d.jpg")
        #expect(S3Signer.encode("a/b", keepSlash: false) == "a%2Fb")
        #expect(S3Signer.encode("A-Z_a.z~0", keepSlash: false) == "A-Z_a.z~0")
    }

    @Test func parsesAListingPage() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>bucket</Name><Prefix>photos/</Prefix><KeyCount>3</KeyCount><IsTruncated>true</IsTruncated>
          <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
          <Contents><Key>photos/</Key><LastModified>2026-01-02T03:04:05.000Z</LastModified><Size>0</Size></Contents>
          <Contents><Key>photos/a &amp; b.jpg</Key><LastModified>2026-01-02T03:04:05.000Z</LastModified><Size>1234</Size></Contents>
          <CommonPrefixes><Prefix>photos/2026/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = S3ListParser.parse(Data(xml.utf8))
        #expect(page.valid)
        #expect(page.truncated)
        #expect(page.nextToken == "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
        #expect(page.items.count == 3)
        #expect(page.items[1] == S3Item(key: "photos/a & b.jpg", size: 1234, modified: Date(timeIntervalSince1970: 1_767_323_045), isFolder: false))
        #expect(page.items[2] == S3Item(key: "photos/2026/", size: 0, modified: nil, isFolder: true))
    }

    @Test func sizesAreNeverNegativeOrAbsurd() {
        let xml = """
        <ListBucketResult><Contents><Key>a</Key><Size>-9223372036854775808</Size></Contents>
        <Contents><Key>b</Key><Size>99999999999999999999</Size></Contents>
        <Contents><Key>c</Key><Size>18014398509481984</Size></Contents></ListBucketResult>
        """
        let sizes = S3ListParser.parse(Data(xml.utf8)).items.map(\.size)
        #expect(sizes == [0, 0, 1 << 44])
    }

    @Test func refusesDocumentTypesAndOtherAnswers() {
        let bomb = """
        <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;">]>
        <ListBucketResult><Contents><Key>&lol2;</Key><Size>1</Size></Contents></ListBucketResult>
        """
        #expect(!S3ListParser.parse(Data(bomb.utf8)).valid)
        #expect(!S3ListParser.parse(Data("<Error><Code>AccessDenied</Code></Error>".utf8)).valid)
        #expect(!S3ListParser.parse(Data("not xml".utf8)).valid)
    }

    @Test func readsErrors() {
        let parsed = S3ErrorParser.parse(Data("<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message></Error>".utf8))
        #expect(parsed.code == "NoSuchBucket")
        #expect(parsed.message == "The specified bucket does not exist")
    }

    // MARK: - Against a stand-in service

    func client() -> S3Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        return S3Client(host: "s3.us-east-1.amazonaws.com", bucket: "my-bucket", region: "us-east-1", pathStyle: false,
                        credentials: credentials, configuration: configuration)
    }

    @Test func aRepeatedContinuationTokenStopsTheListing() async {
        FakeS3.answer = { _ in
            (200, [:], Data("""
            <ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>same</NextContinuationToken>
            <Contents><Key>a.txt</Key><Size>1</Size></Contents></ListBucketResult>
            """.utf8))
        }
        await #expect(throws: S3Error.badResponse) { _ = try await client().list("") }
    }

    @Test func redirectsAreNotFollowed() async {
        FakeS3.answer = { request in
            request.url?.host == "s3.us-east-1.amazonaws.com" || request.url?.host == "my-bucket.s3.us-east-1.amazonaws.com"
                ? (301, ["Location": "https://elsewhere.example.com/steal"], Data())
                : (200, [:], Data("<ListBucketResult></ListBucketResult>".utf8))
        }
        do {
            _ = try await client().list("")
            #expect(Bool(false), "a redirect should not be followed")
        } catch let S3Error.service(status, _, _) {
            #expect(status == 301)
        } catch {
            #expect(Bool(false), "\(error)")
        }
        #expect(!FakeS3.hosts.contains("elsewhere.example.com"))
    }

    @Test func aCopyCountsOnlyWithItsResult() async throws {
        FakeS3.answer = { _ in (200, [:], Data("<Nothing/>".utf8)) }
        await #expect(throws: S3Error.badResponse) { try await client().copy("a", to: "b") }
        FakeS3.answer = { _ in (200, [:], Data("<CopyObjectResult><ETag>x</ETag></CopyObjectResult>".utf8)) }
        try await client().copy("a", to: "b")
    }

    @Test func downloadsStopAtTheListedSize() async throws {
        FakeS3.answer = { _ in (200, [:], Data(repeating: 7, count: 300_000)) }
        let destination = FileManager.default.temporaryDirectory.appending(path: "strata-s3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        await #expect(throws: S3Error.changed) { try await client().download("big.bin", to: destination, limit: 1000) }
        try await client().download("big.bin", to: destination, limit: 300_000)
        #expect(try Data(contentsOf: destination).count == 300_000)
    }
}

/// Answers S3 requests in tests, recording the hosts asked.
nonisolated final class FakeS3: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: (URLRequest) -> (Int, [String: String], Data) = { _ in (500, [:], Data()) }
    nonisolated(unsafe) static var hosts: Set<String> = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.hosts.insert(request.url?.host ?? "")
        let (status, headers, body) = Self.answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

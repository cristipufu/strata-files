import CNativeReaderTestSupport
import Foundation
import Testing
@testable import StrataFiles

struct S3NativeXMLTests {
    @Test func listingExceptionsReturnAnInvalidPageBeforeUnwindingTheCaller() {
        var page: S3ListParser?
        let escaped = STTestXMLBoundary { parser in
            page = S3ListParser.parse(Data("<ListBucketResult/>".utf8), makeParser: { _ in parser })
        }
        #expect(escaped == nil)
        #expect(page?.valid == false)
        #expect(page?.items.isEmpty == true)
    }

    @Test func errorExceptionsReturnAnEmptyErrorBeforeUnwindingTheCaller() {
        var reply: S3ErrorParser?
        let escaped = STTestXMLBoundary { parser in
            reply = S3ErrorParser.parse(Data("<Error/>".utf8), makeParser: { _ in parser })
        }
        #expect(escaped == nil)
        #expect(reply?.code.isEmpty == true && reply?.message.isEmpty == true)
    }

    @Test func truncatedResponsesNeverPublishPartialErrorFields() {
        let partial = S3ErrorParser.parse(Data("<Error><Code>NoSuchKey</Code><Message>unfinished".utf8))
        #expect(partial.code.isEmpty && partial.message.isEmpty)
        let valid = S3ErrorParser.parse(Data("<Error><Code>NoSuchKey</Code><Message>Gone</Message></Error>".utf8))
        #expect(valid.code == "NoSuchKey" && valid.message == "Gone")
        #expect(S3ListParser.parse(Data("<ListBucketResult/>".utf8)).valid)
    }
}

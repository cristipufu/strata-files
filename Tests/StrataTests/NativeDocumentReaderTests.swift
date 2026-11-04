import AppKit
import CNativeReaders
import CNativeReaderTestSupport
import Testing
@testable import Strata
@testable import StrataAI

@MainActor struct NativeDocumentReaderTests {
    private func pdf(text: String?, size: CGSize = CGSize(width: 300, height: 300)) throws -> Data {
        let page = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: page))
        var bounds = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        if let text {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 20, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        }
        context.endPDFPage(); context.closePDF()
        return page as Data
    }


    @Test func richTextExtractionUsesTheNativeReaderAndPreservesItsSource() async throws {
        let tree = try TestTree("document.rtf")
        let data = Data("{\\rtf1\\ansi A chosen document.}".utf8)
        try data.write(to: tree.url("document.rtf"))
        let text = try #require(await TextExtractor.extract(tree.url("document.rtf")))
        #expect(text.text == "A chosen document.")
        #expect(text.source == .rich)
        #expect(try Data(contentsOf: tree.url("document.rtf")) == data)
        #expect(tree.snapshot() == ["document.rtf"])
    }

    @Test func aNativeXMLExceptionBecomesAnOrdinaryError() throws {
        let error = try #require(STTestXMLException()) as NSError
        #expect(error.domain == "StrataNativeRead")
        #expect(error.userInfo["operation"] as? String == "XML parsing")
    }

    @Test func aNativeRichTextExceptionBecomesAnOrdinaryError() throws {
        let error = try #require(STTestRichTextException()) as NSError
        #expect(error.domain == "StrataNativeRead")
        #expect(error.userInfo["operation"] as? String == "rich text extraction")
    }

    @Test func pdfTextErrorsAbandonTheDocumentAndTheNextReadIsIndependent() throws {
        let document = STReaderTestDocument()
        let reader = try STPDFReader.open(document)
        document.failsText = true
        #expect(throws: (any Error).self) {
            try reader.read(maxCharacters: 100, maxPages: 3, cancelled: { false })
        }
        #expect(reader.failure != nil)
        #expect(throws: (any Error).self) { try reader.read(maxCharacters: 100, maxPages: 3, cancelled: { false }) }
        #expect(throws: (any Error).self) { try reader.image(forPage: 0) }
        #expect(document.textReads == 1)
        let next = STReaderTestDocument()
        let result = try STPDFReader.open(next).read(maxCharacters: 100, maxPages: 3, cancelled: { false })
        #expect(result.text.contains("中文 😀"))
        #expect(result.pageStarts.count == 3 && result.pageCount == 3)
    }

    @Test func pdfCancellationStopsBeforeTheNextNativePage() throws {
        let document = STReaderTestDocument()
        let reader = try STPDFReader.open(document)
        #expect(throws: (any Error).self) {
            try reader.read(maxCharacters: 100, maxPages: 3,
                                     cancelled: { document.textReads == 1 })
        }
        #expect(document.textReads == 1)
        #expect(reader.failure != nil)
        #expect(throws: (any Error).self) { try reader.read(maxCharacters: 100, maxPages: 3, cancelled: { false }) }
        #expect(document.textReads == 1)
    }

    @Test func pdfThumbnailFailuresUseTheSameErrorBoundary() {
        let document = STReaderTestDocument()
        document.scanned = true
        document.failsThumbnail = true
        #expect(throws: (any Error).self) {
            try STPDFReader.open(document).image(forPage: 0)
        }
    }

    @Test(arguments: [0, 1, 4, 6, 10, 100])
    func nativeTextOutputsStayWithinTheirUTF16BudgetWithoutSplittingCharacters(_ limit: Int) throws {
        let document = STReaderTestDocument()
        let result = try STPDFReader.open(document).read(maxCharacters: UInt(limit), maxPages: 3, cancelled: { false })
        #expect(result.text.utf16.count <= limit)
        #expect(!result.text.unicodeScalars.contains("\u{FFFD}"))
        if limit < 10 { #expect(result.truncated) }
    }

    @Test func realPDFExtractionRemainsBoundedAndDoesNotChangeTheFile() async throws {
        let tree = try TestTree("document.pdf")
        let data = try pdf(text: "Chosen PDF text")
        try data.write(to: tree.url("document.pdf"))
        let text = try #require(await TextExtractor.extract(tree.url("document.pdf")))
        #expect(text.text.contains("Chosen PDF text") && text.pageCount == 1)
        #expect(text.pageStarts == [0])
        #expect(try Data(contentsOf: tree.url("document.pdf")) == data)
        #expect(tree.snapshot() == ["document.pdf"])
    }

    @Test func oversizedNativePageCountsAreRefusedBeforeAnyPageRead() {
        let document = STReaderTestDocument()
        document.availablePages = UInt.max
        #expect(throws: (any Error).self) { try STPDFReader.open(document) }
        #expect(document.textReads == 0)
    }

    @Test func nativeMetadataKeepsTheCallersExistingUnicodeTitlePolicy() throws {
        let document = STReaderTestDocument()
        document.providedTitle = String(repeating: "😀", count: 150)
        let result = try STPDFReader.open(document).read(maxCharacters: 100, maxPages: 1, cancelled: { false })
        #expect(result.title == document.providedTitle)
    }

    @Test func anExactlyFittingPDFIsNotReportedAsTruncated() throws {
        let document = STReaderTestDocument()
        document.availablePages = 1
        let reader = try STPDFReader.open(document)
        let full = try reader.read(maxCharacters: 100, maxPages: 3, cancelled: { false })
        let exact = try reader.read(maxCharacters: UInt(full.text.utf16.count), maxPages: 3, cancelled: { false })
        #expect(exact.text == full.text)
        #expect(!exact.truncated)
    }
    @Test func scannedPagesAreRasterizedOnDemandAndOwnTheirPixelsAfterTheReaderCloses() throws {
        let data = try pdf(text: nil, size: CGSize(width: 5000, height: 4000))
        weak var closed: STPDFReader?
        let bitmap = try autoreleasepool {
            let reader = try STPDFReader.open(data)
            closed = reader
            let result = try reader.read(maxCharacters: 100, maxPages: 3, cancelled: { false })
            #expect(result.scannedPageIndexes.map(\.intValue) == [0])
            return try reader.image(forPage: 0)
        }
        #expect(closed == nil)
        #expect(bitmap.image.width > 0 && bitmap.image.width <= 2200)
        #expect(bitmap.image.height > 0 && bitmap.image.height <= 2200)
        let pixels = try #require(bitmap.image.dataProvider?.data)
        #expect(CFDataGetLength(pixels) > 0)
    }

}

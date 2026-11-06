import AppKit
import Testing

enum PDFPreviewFixture {
    static func data(text: String = "Strata PDF needle 中文") throws -> Data {
        try data(pages: [text])
    }

    static func data(pages: [String]) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 40, y: 280), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

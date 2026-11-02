import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct TextExtractorTests {
    @Test func namedDecimalAndHexReferencesBecomeTheirCharacters() {
        #expect(TextExtractor.decodeEntities("A &amp; B &AMP; C") == "A & B & C")
        #expect(TextExtractor.decodeEntities("") == "")
        #expect(TextExtractor.decodeEntities("&#1;&#x10FFFF;") == "\u{1}\u{10FFFF}")
        #expect(TextExtractor.decodeEntities("pages 3&#150;5, &#147;quoted&#148; &#128;9") == "pages 3–5, “quoted” €9")
        #expect(TextExtractor.decodeEntities("&lt;p&gt; &quot;hi&quot; &rsquo;s &hellip;") == "<p> \"hi\" ’s …")
        #expect(TextExtractor.decodeEntities("&#38; &#x26; &#X26; &#x1F600;") == "& & & 😀")
        #expect(TextExtractor.decodeEntities("&amp;amp; &&amp; café &#233;") == "&amp; && café é")
    }

    @Test func unknownMalformedAndUnusableReferencesStayAsWritten() {
        for text in ["&unknown;", "&amp", "& amp;", "&;", "&#;", "&#x;", "&#12a;", "&#xZZ;", "&frac12;", "&",
                     "&#0;", "&#x0;", "&#xD800;", "&#x110000;", "&#99999999999999999999;", "a & b", "&#", "&#x",
                     "&Mdash;", "&AMp;", "&#129;", "&#x8D;", "&#143;", "&#144;", "&#157;"] {
            #expect(TextExtractor.decodeEntities(text) == text, "\(text)")
        }
        #expect(TextExtractor.decodeEntities("&#0;&amp;") == "&#0;&")
    }

    @Test func longRunsWithoutASemicolonStayAsWritten() {
        let digits = "&#" + String(repeating: "1", count: 200_000)
        #expect(TextExtractor.decodeEntities(digits + "&amp;") == digits + "&")
        let ampersands = String(repeating: "&", count: 200_000)
        #expect(TextExtractor.decodeEntities(ampersands) == ampersands)
    }

    @Test func htmlTextAndTitleDecodeReferences() {
        let page = TextExtractor.html("<html><head><title>Q&amp;A &#8212; notes</title></head><body><p>Fish &amp; chips</p></body></html>")
        #expect(page.title == "Q&A — notes")
        #expect(page.text.contains("Fish & chips"))
    }

    @Test(arguments: [
        ("<p>one</p><p>two</p>", "\none\n\ntwo\n"),
        ("<b>bold</b> and <i>it</i>", " bold  and  it "),
        ("a < b and c > d", "a < b and c > d"),
        ("a <!-- hidden --> b", "a   b"),
        ("a <!-- never closed", "a  "),
        ("x<SCRIPT>alert(1)</script>y", "x y"),
        ("x<style>p { }</STYLE >y", "x y"),
        ("shown<script>never closed", "shown "),
        ("<DIV>Up</DIV><br/>end", "\nUp\n\nend"),
        ("<h2>Sub</h2><x-tag>custom</x-tag>", "\nSub\n custom "),
        ("<title>T</title><p>body</p>", " T \nbody\n"),
    ])
    func htmlKeepsWhatAReaderSees(source: String, text: String) {
        #expect(TextExtractor.html(source).text == text)
    }

    @Test func htmlTitleIsTheTitleElseTheFirstHeading() {
        #expect(TextExtractor.html("<h1>First <b>bold</b></h1><h1>Second</h1>").title == "First  bold ")
        #expect(TextExtractor.html("<h1>Heading</h1><TITLE>Named</TITLE>").title == "Named")
        #expect(TextExtractor.html("<title>Open to the end").title == "Open to the end")
        #expect(TextExtractor.html("<titles>no</titles><p>none</p>").title == nil)
        #expect(TextExtractor.html("<p>plain</p>").title == nil)
    }
}

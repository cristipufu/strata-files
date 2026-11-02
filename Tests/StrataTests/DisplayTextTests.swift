import Testing
@testable import StrataSupport

struct DisplayTextTests {
    @Test func oneLineKeepsWhatShowsAndDropsWhatHidesOrBreaksIt() {
        // A NUL, a line separator and a tab become spaces; a right-to-left override, a Hangul filler and a zero-width
        // space go.
        #expect(DisplayText.oneLine("a\u{0}b\u{202E}c\u{2028}d\u{3164}e\u{200B}f\tg") == "a bc def g")
        // Combining marks, emoji joiners, variation selectors and tags, and a Persian non-joiner stay.
        let flag = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        #expect(DisplayText.oneLine(flag) == flag)
        let kept = "Cafe\u{0301} \u{1F469}\u{200D}\u{1F4BB} \u{2764}\u{FE0F} "
            + "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
        #expect(DisplayText.oneLine(kept) == kept)
    }

    @Test func aLabelStopsAtItsBytesBetweenScalars() {
        // A run of combining marks is cut too, never through a scalar.
        let marks = DisplayText.label("A" + String(repeating: "\u{301}", count: 2000))
        #expect(marks.utf8.count == 1199 && marks.unicodeScalars.first == "A")
        let faces = String(repeating: "\u{1F600}", count: 400)
        #expect(DisplayText.label(faces) == String(faces.prefix(300)))
        #expect(DisplayText.label(String(repeating: "x", count: 1200)).count == 1200)
        #expect(DisplayText.label("Short") == "Short")
    }
}

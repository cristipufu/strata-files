import Testing
@testable import Strata

struct SoundsTests {
    @Test func aTestProcessPlaysNoSound() {
        // Only the app's executable turns sounds on: tests refuse and trash things all the time.
        #expect(!Sounds.areOn)
    }
}

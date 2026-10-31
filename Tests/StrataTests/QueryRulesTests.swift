import Foundation
import Testing
@testable import StrataAI

/// What each of the search parser's size and date rules sets, at a fixed time and calendar.
struct QueryRulesTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)
    private static let dates = Dates(now: now, calendar: calendar)

    private static func filter(_ text: String) -> SearchFilter {
        QueryInterpreter.parse(text, now: now, calendar: calendar).filter
    }

    private static func ago(_ value: Int, _ component: Calendar.Component) -> Date? {
        calendar.date(byAdding: component, value: -value, to: now)
    }

    @Test(arguments: [
        ("bigger than 10mb", 10_000_000, nil),
        ("at least 5 kb", 5_000, nil),
        ("smaller than 2 gb", nil, 2_000_000_000),
        ("up to 3 kib", nil, 3_072),
        ("10mb or more", 10_000_000, nil),
        ("3 gib+", 3_221_225_472, nil),
        ("100 kb or less", nil, 100_000),
        ("between 1 and 2 gb", 1_000_000_000, 2_000_000_000),
        (">= 4 mb", 4_000_000, nil),
    ] as [(String, Int64?, Int64?)])
    func aSizeSetsItsBound(text: String, minimum: Int64?, maximum: Int64?) {
        let filter = Self.filter(text)
        #expect(filter.minSize == minimum)
        #expect(filter.maxSize == maximum)
    }

    @Test func aCountedSpanSetsItsBound() {
        #expect(Self.filter("older than 3 weeks").modifiedBefore == Self.ago(21, .day))
        #expect(Self.filter("older than 3 weeks").modifiedAfter == nil)
        #expect(Self.filter("not modified in the last 2 months").modifiedBefore == Self.ago(2, .month))
        #expect(Self.filter("newer than 2 days").modifiedAfter == Self.ago(2, .day))
        #expect(Self.filter("in the last 6 hours").modifiedAfter == Self.ago(6, .hour))
        #expect(Self.filter("past 4 minutes").modifiedAfter == Self.ago(4, .minute))
        #expect(Self.filter("5 years old").modifiedBefore == Self.ago(5, .year))
        #expect(Self.filter("5 years old").modifiedAfter == nil)
    }

    @Test func aSpanThatIsntOneLeavesTheDatesAlone() {
        let filter = Self.filter("older than 3 widgets")
        #expect(filter.modifiedBefore == nil && filter.modifiedAfter == nil)
    }

    @Test func periodsByNameAndCalendarDatesSetTheirRange() {
        let lastMonth = Self.filter("last month")
        #expect(lastMonth.modifiedAfter == Self.dates.previous(.month).0)
        #expect(lastMonth.modifiedBefore == Self.dates.previous(.month).1)
        #expect(Self.filter("today").modifiedAfter == Self.dates.today().0)
        let range = Self.filter("between 2025-03-03 and 2025-04-09")
        #expect(range.modifiedAfter == Self.dates.day(year: 2025, month: 3, day: 3).0)
        #expect(range.modifiedBefore == Self.dates.day(year: 2025, month: 4, day: 9).1)
        #expect(Self.filter("before 2024").modifiedBefore == Self.dates.year(2024).0)
        #expect(Self.filter("recently").modifiedAfter == Self.ago(7, .day))
    }

    /// A counted span is read before a period by name, and both before calendar dates: "the last 3 weeks" is a span,
    /// not "last week" with a stray number.
    @Test func spansComeBeforePeriodsAndCalendarDates() {
        let filter = Self.filter("pdfs in the last 3 weeks bigger than 10mb")
        #expect(filter.modifiedAfter == Self.ago(21, .day))
        #expect(filter.modifiedBefore == nil)
        #expect(filter.minSize == 10_000_000)
    }
}

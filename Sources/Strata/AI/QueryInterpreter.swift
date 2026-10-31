import Foundation
import FoundationModels

/// What a search phrase was understood as, and by what.
package nonisolated struct QueryInterpretation: Sendable {
    package enum Source: String, Sendable {
        /// The deterministic parser understood everything.
        case rules
        /// The on-device model filled in what the rules couldn't place.
        case rulesAndModel
    }

    package var filter: SearchFilter
    package var source: Source
    /// Words the rules couldn't place. Without the model they stay in `filter.keywords` (matched against names).
    package var unrecognized: [String]
}

/// Turns a natural-language search ("pdfs from last week bigger than 10mb about invoices") into a `SearchFilter`.
///
/// A deterministic parser handles operators (`ext:pdf`, `kind:image`, `size:>10mb`, `modified:<7d`, `name:acme`) and common
/// phrasing (kinds, sizes, "today", "last week", "older than 30 days", "in 2024", "since March", "named …", "about …") with no
/// model and no latency. Only when words are left over, and Apple Intelligence is available, the on-device model reads the whole
/// phrase with guided generation (constrained to the filter's shape); the rules' explicit findings always win.
package nonisolated enum QueryInterpreter {
    // MARK: - Entry points

    package static func interpret(_ text: String, now: Date = .now, calendar: Calendar = .current, allowModel: Bool = true,
                          timeout: Double = 6) async -> QueryInterpretation {
        let rules = parse(text, now: now, calendar: calendar)
        guard allowModel, !rules.unrecognized.isEmpty, AIModel.isAvailable else { return rules }
        do {
            let modelFilter = try await Deadline.run(timeout) { try await askModel(text, now: now, calendar: calendar) }
            return merge(rules, modelFilter)
        } catch {
            return rules
        }
    }

    /// The deterministic fast path: no model, no I/O, a millisecond or so.
    package static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> QueryInterpretation {
        let parser = Parser(text, now: now, calendar: calendar)
        parser.run()
        var filter = parser.filter
        filter.keywords = parser.leftovers
        return QueryInterpretation(filter: filter, source: .rules, unrecognized: parser.leftovers)
    }

    /// Rules first; the model fills only what the rules left empty and takes over the unplaced words.
    package static func merge(_ rules: QueryInterpretation, _ model: SearchFilter) -> QueryInterpretation {
        var filter = rules.filter
        if filter.kinds.isEmpty, filter.extensions.isEmpty {
            filter.kinds = model.kinds
            filter.extensions = model.extensions
        }
        if filter.minSize == nil, filter.maxSize == nil {
            filter.minSize = model.minSize
            filter.maxSize = model.maxSize
        }
        if filter.modifiedAfter == nil, filter.modifiedBefore == nil {
            filter.modifiedAfter = model.modifiedAfter
            filter.modifiedBefore = model.modifiedBefore
        }
        // The model read the leftover words in context: they become name fragments or a topic.
        filter.keywords = []
        filter.nameContains = Array(NSOrderedSet(array: filter.nameContains + model.nameContains)) as? [String] ?? filter.nameContains
        if filter.contentQuery == nil { filter.contentQuery = model.contentQuery }
        if filter.nameContains.isEmpty, filter.contentQuery == nil, !rules.unrecognized.isEmpty {
            // The model placed nothing: don't lose the words.
            filter.keywords = rules.unrecognized
        }
        return QueryInterpretation(filter: filter, source: .rulesAndModel, unrecognized: [])
    }

    // MARK: - Model

    package static let dateRanges = ["any", "today", "yesterday", "thisWeek", "lastWeek", "thisMonth", "lastMonth", "thisYear", "lastYear",
                             "lastDays", "olderThanDays", "year", "since", "before", "between"]

    package static func schema() throws -> GenerationSchema {
        let kind = Schema.choice("Kind", SearchFilter.Kind.allCases.map(\.rawValue))
        return try Schema.root(Schema.object("FileSearch", "A filter for finding files on a Mac", [
            Schema.field("kinds", "Kinds of files asked for; empty if none named", Schema.array(kind, max: 4)),
            Schema.field("extensions", "File extensions without the dot, only if the request names one", Schema.array(Schema.string(), max: 6)),
            Schema.field("minSize", "Minimum size like \"10 MB\", only for bigger/larger/over", Schema.string(), optional: true),
            Schema.field("maxSize", "Maximum size like \"500 KB\", only for smaller/under", Schema.string(), optional: true),
            Schema.field("dateRange", "When the files were modified", Schema.choice("DateRange", dateRanges)),
            Schema.field("days", "Number of days, for lastDays or olderThanDays", Schema.integer(1...3650), optional: true),
            Schema.field("year", "The year, for dateRange year", Schema.integer(1990...2100), optional: true),
            Schema.field("start", "YYYY-MM-DD, for since or between", Schema.string(), optional: true),
            Schema.field("end", "YYYY-MM-DD, for before or between", Schema.string(), optional: true),
            Schema.field("nameContains", "Words the file NAME must contain, only if the request says named, called or titled",
                         Schema.array(Schema.string(), max: 3)),
            Schema.field("contentQuery", "What the documents are about, a few words, for searching inside them", Schema.string(), optional: true),
        ]))
    }

    package static func instructions(now: Date, calendar: Calendar) -> String {
        let today = now.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
        let weekday = now.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide))
        return """
        You turn a request to find files on a Mac into a search filter. Today is \(weekday), \(today).
        Fill only what the request asks for and leave everything else empty. Topics go in contentQuery; words that must appear \
        in the file name go in nameContains.
        Example: "big videos from last month" → kinds [movie], minSize "100 MB", dateRange lastMonth.
        Example: "notes about the Lisbon trip" → kinds [document], contentQuery "Lisbon trip".
        """
    }

    package static func askModel(_ text: String, now: Date, calendar: Calendar) async throws -> SearchFilter {
        let session = LanguageModelSession(model: SystemLanguageModel(useCase: .general), instructions: instructions(now: now, calendar: calendar))
        let response = try await session.respond(to: "Request: \(text)", schema: try schema(),
                                                 options: .greedy(maximumResponseTokens: 220))
        return decode(response.content, now: now, calendar: calendar)
    }

    /// Model output → filter. Relative dates are computed here, not by the model (small models get date arithmetic wrong).
    package static func decode(_ content: GeneratedContent, now: Date, calendar: Calendar) -> SearchFilter {
        var filter = SearchFilter()
        filter.kinds = Set(content["kinds"]?.strings.compactMap(SearchFilter.Kind.init(rawValue:)) ?? [])
        filter.extensions = Set((content["extensions"]?.strings ?? []).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty && $0.count <= 8 })
        filter.minSize = content["minSize"]?.meaningfulString.flatMap(Parser.size)
        filter.maxSize = content["maxSize"]?.meaningfulString.flatMap(Parser.size)
        let dates = Dates(now: now, calendar: calendar)
        let days = content["days"]?.integer
        var range: (Date?, Date?) = (nil, nil)
        switch content["dateRange"]?.string ?? "any" {
        case "today": range = dates.today()
        case "yesterday": range = dates.yesterday()
        case "thisWeek": range = dates.current(.weekOfYear)
        case "lastWeek": range = dates.previous(.weekOfYear)
        case "thisMonth": range = dates.current(.month)
        case "lastMonth": range = dates.previous(.month)
        case "thisYear": range = dates.current(.year)
        case "lastYear": range = dates.previous(.year)
        case "lastDays": if let days { range = (dates.ago(days, .day), nil) }
        case "olderThanDays": if let days { range = (nil, dates.ago(days, .day)) }
        case "year": if let year = content["year"]?.integer { range = dates.year(year) }
        case "since": range = (content["start"]?.meaningfulString.flatMap(dates.isoDay), nil)
        case "before": range = (nil, content["end"]?.meaningfulString.flatMap(dates.isoDay))
        case "between":
            range = (content["start"]?.meaningfulString.flatMap(dates.isoDay),
                     content["end"]?.meaningfulString.flatMap(dates.isoDay).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) })
        default: break
        }
        (filter.modifiedAfter, filter.modifiedBefore) = range
        filter.nameContains = Array((content["nameContains"]?.strings ?? []).prefix(3))
        filter.contentQuery = content["contentQuery"]?.meaningfulString
        return filter
    }
}

// MARK: - Dates

/// Calendar ranges relative to "now". Ranges are [after, before).
package nonisolated struct Dates {
    package let now: Date
    package let calendar: Calendar

    package func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    package func today() -> (Date?, Date?) { (startOfDay(now), nil) }
    package func yesterday() -> (Date?, Date?) {
        let today = startOfDay(now)
        return (calendar.date(byAdding: .day, value: -1, to: today), today)
    }
    package func current(_ unit: Calendar.Component) -> (Date?, Date?) { (calendar.dateInterval(of: unit, for: now)?.start, nil) }
    package func previous(_ unit: Calendar.Component) -> (Date?, Date?) {
        guard let current = calendar.dateInterval(of: unit, for: now),
              let previous = calendar.dateInterval(of: unit, for: current.start.addingTimeInterval(-1)) else { return (nil, nil) }
        return (previous.start, current.start)
    }
    package func ago(_ count: Int, _ unit: Calendar.Component) -> Date? {
        let bounded = boundedCount(Double(count))
        if unit == .weekOfYear { return calendar.date(byAdding: .day, value: -7 * bounded, to: now) }
        return calendar.date(byAdding: unit, value: -bounded, to: now)
    }
    /// The whole calendar unit that contained "N units ago" ("3 days ago" = that day).
    package func unit(containing count: Int, _ unit: Calendar.Component) -> (Date?, Date?) {
        guard let date = ago(count, unit) else { return (nil, nil) }
        let component: Calendar.Component = unit == .hour || unit == .minute ? .day : unit
        guard let interval = calendar.dateInterval(of: component, for: date) else { return (nil, nil) }
        return (interval.start, interval.end)
    }
    package func year(_ year: Int) -> (Date?, Date?) {
        let y = min(max(year, 1), 99_999)
        return (calendar.date(from: DateComponents(year: y, month: 1, day: 1)),
                calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1)))
    }
    /// A month without a year means the latest one that has started.
    package func month(_ month: Int, year: Int?) -> (Date?, Date?) {
        let thisYear = calendar.component(.year, from: now)
        let thisMonth = calendar.component(.month, from: now)
        let y = year ?? (month <= thisMonth ? thisYear : thisYear - 1)
        guard let start = calendar.date(from: DateComponents(year: y, month: month, day: 1)) else { return (nil, nil) }
        return (start, calendar.date(byAdding: .month, value: 1, to: start))
    }
    package func day(year: Int?, month: Int, day: Int) -> (Date?, Date?) {
        let thisYear = calendar.component(.year, from: now)
        var y = year ?? thisYear
        guard var start = calendar.date(from: DateComponents(year: y, month: month, day: day)) else { return (nil, nil) }
        if year == nil, start > now {
            y -= 1
            start = calendar.date(from: DateComponents(year: y, month: month, day: day)) ?? start
        }
        return (start, calendar.date(byAdding: .day, value: 1, to: start))
    }
    /// The latest such weekday on or before today (strictly before with `last`).
    package func weekday(_ weekday: Int, strictlyBefore: Bool) -> (Date?, Date?) {
        var date = startOfDay(now)
        for _ in 0..<8 {
            if calendar.component(.weekday, from: date) == weekday, !(strictlyBefore && calendar.isDate(date, inSameDayAs: now)) {
                return (date, calendar.date(byAdding: .day, value: 1, to: date))
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return (nil, nil)
    }
    package func isoDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Parser

/// Regex passes over a lowercased copy of the query. Each pass blanks what it understood; the words left at the end are leftovers.
private nonisolated final class Parser {
    var filter = SearchFilter()
    var leftovers: [String] = []
    private var text: NSMutableString
    private let original: String
    private let dates: Dates

    init(_ query: String, now: Date, calendar: Calendar) {
        original = query
        // Curly quotes → straight; lowercase for matching (quoted names are re-read from the original case).
        text = NSMutableString(string: query.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'").lowercased())
        dates = Dates(now: now, calendar: calendar)
    }

    static let num = "(\\d+(?:[.,]\\d+)?|a couple of|couple of|a few|few|several|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|sixty|ninety)"
    static let sizeUnit = "(bytes?|b|kilobytes?|kib|kb|k|megabytes?|megs?|mib|mb|m|gigabytes?|gigs?|gib|gb|g|terabytes?|tib|tb|t)"
    static let timeUnit = "(minutes?|mins?|hours?|hrs?|h|days?|d|weeks?|wks?|w|months?|mos?|years?|yrs?|y)"
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    func run() {
        operators()
        sizes()
        datesPass()
        kindsPass()
        names()
        content()
        quoted()
        collectLeftovers()
    }

    // MARK: Operators

    private func operators() {
        consume("\\b(?:ext|extension|type|kind|is)\\s*:\\s*\\.?([\\w,.]+)") { m in
            for item in (m[1] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }) where !item.isEmpty {
                if let kind = Self.kindAliases[item] { self.filter.kinds.insert(kind) } else { self.filter.extensions.insert(item) }
            }
            return true
        }
        consume("\\bsize\\s*:\\s*(>=|<=|>|<|=)?\\s*(\\d+(?:\\.\\d+)?)\\s*\(Self.sizeUnit)?\\b") { m in
            guard let value = Double(m[2] ?? "") else { return false }
            let bytes = saturatingInt64(value * Self.multiplier(m[3] ?? "mb")) ?? 0
            switch m[1] {
            case "<", "<=": self.filter.maxSize = bytes
            case "=":
                self.filter.minSize = saturatingInt64(Double(bytes) * 0.9)
                self.filter.maxSize = saturatingInt64(Double(bytes) * 1.1)
            default: self.filter.minSize = bytes
            }
            return true
        }
        consume("\\b(?:modified|changed|edited|updated|date|mtime)\\s*:\\s*(>=|<=|>|<)\\s*(\\d+)\\s*(mo|h|d|w|m|y)\\b") { m in
            guard let count = Double(m[2] ?? ""), let unit = Self.timeComponent(m[3] ?? "") else { return false }
            let date = self.dates.ago(boundedCount(count), unit)
            if m[1]?.hasPrefix("<") == true { self.filter.modifiedAfter = date } else { self.filter.modifiedBefore = date }
            return true
        }
        consume("\\b(?:modified|changed|edited|updated|date|mtime)\\s*:\\s*(\\d{4})(?:-(\\d{1,2}))?(?:-(\\d{1,2}))?\\b") { m in
            guard let year = Int(m[1] ?? "") else { return false }
            let range: (Date?, Date?)
            if let month = m[2].flatMap(Int.init), let day = m[3].flatMap(Int.init) {
                range = self.dates.day(year: year, month: month, day: day)
            } else if let month = m[2].flatMap(Int.init) {
                range = self.dates.month(month, year: year)
            } else {
                range = self.dates.year(year)
            }
            self.setDates(range)
            return true
        }
        // "modified:today", "modified:last week": drop the prefix and let the date pass read the rest.
        consume("\\b(?:modified|changed|edited|updated|date)\\s*:") { _ in true }
        consume("\\bname\\s*:\\s*(\"[^\"]+\"|'[^']+'|\\S+)") { m in
            self.addName(m.originalGroup(1))
            return true
        }
        consume("\\b(?:content|text|about)\\s*:\\s*(.+)$") { m in
            self.filter.contentQuery = Self.cleanTopic(m.originalGroup(1))
            return self.filter.contentQuery != nil
        }
    }

    // MARK: Sizes

    private func sizes() {
        consume("\\bbetween\\s+(\\d+(?:[.,]\\d+)?)\\s*\(Self.sizeUnit)?\\s*(?:and|to|-)\\s*(\\d+(?:[.,]\\d+)?)\\s*\(Self.sizeUnit)\\b") { m in
            guard let low = Self.number(m[1]), let high = Self.number(m[3]) else { return false }
            let unit = m[4] ?? "mb"
            self.filter.minSize = saturatingInt64(low * Self.multiplier(m[2] ?? unit))
            self.filter.maxSize = saturatingInt64(high * Self.multiplier(unit))
            return true
        }
        consume("\\b(?:bigger|larger|greater|heavier|more|over|above|exceeding|at least)\\s*(?:than\\s+|then\\s+)?\(Self.num)\\s*\(Self.sizeUnit)\\b") { m in
            guard let value = Self.number(m[1]) else { return false }
            self.filter.minSize = saturatingInt64(value * Self.multiplier(m[2] ?? "mb"))
            return true
        }
        consume("\\b(?:smaller|less|lighter|under|below|at most|up to|no more)\\s*(?:than\\s+|then\\s+)?\(Self.num)\\s*\(Self.sizeUnit)\\b") { m in
            guard let value = Self.number(m[1]) else { return false }
            self.filter.maxSize = saturatingInt64(value * Self.multiplier(m[2] ?? "mb"))
            return true
        }
        consume("(?:^|\\s)(>=?|<=?)\\s*(\\d+(?:[.,]\\d+)?)\\s*\(Self.sizeUnit)\\b") { m in
            guard let value = Self.number(m[2]) else { return false }
            let bytes = saturatingInt64(value * Self.multiplier(m[3] ?? "mb")) ?? 0
            if m[1]?.hasPrefix(">") == true { self.filter.minSize = bytes } else { self.filter.maxSize = bytes }
            return true
        }
        consume("\\b(\\d+(?:[.,]\\d+)?)\\s*\(Self.sizeUnit)\\s*(\\+|or (?:more|bigger|larger|above)|and (?:up|above))") { m in
            guard let value = Self.number(m[1]) else { return false }
            self.filter.minSize = saturatingInt64(value * Self.multiplier(m[2] ?? "mb"))
            return true
        }
        consume("\\b(\\d+(?:[.,]\\d+)?)\\s*\(Self.sizeUnit)\\s*or (?:less|smaller|below)\\b") { m in
            guard let value = Self.number(m[1]) else { return false }
            self.filter.maxSize = saturatingInt64(value * Self.multiplier(m[2] ?? "mb"))
            return true
        }
        // Adjectives, as rough sizes (only if nothing more precise was said).
        consume("\\b(huge|enormous|gigantic|massive)\\b") { _ in self.setMin(1_000_000_000) }
        consume("\\b(large|big|biggest|largest|heavy)\\b") { _ in self.setMin(100_000_000) }
        consume("\\b(tiny)\\b") { _ in self.setMax(100_000) }
        consume("\\b(small|smallest)\\b") { _ in self.setMax(1_000_000) }
        consume("\\b(empty)\\b") { _ in self.setMax(0) }
    }

    private func setMin(_ bytes: Int64) -> Bool {
        if filter.minSize == nil, filter.maxSize == nil { filter.minSize = bytes }
        return true
    }

    private func setMax(_ bytes: Int64) -> Bool {
        if filter.minSize == nil, filter.maxSize == nil { filter.maxSize = bytes }
        return true
    }

    // MARK: Dates

    private func datesPass() {
        let num = Self.num, unit = Self.timeUnit
        consume("\\b(?:older than|more than|over|at least|not (?:modified|touched|changed|opened|edited|used) (?:in|for)(?: the)?(?: last| past)?)\\s+\(num)\\s+\(unit)(?:\\s+(?:old|ago))?\\b") { m in
            guard let count = Self.number(m[1]), let component = Self.timeComponent(m[2] ?? "") else { return false }
            self.filter.modifiedBefore = self.dates.ago(boundedCount(count), component)
            return true
        }
        consume("\\b(?:newer|younger|less|fewer) than\\s+\(num)\\s+\(unit)(?:\\s+(?:old|ago))?\\b") { m in
            guard let count = Self.number(m[1]), let component = Self.timeComponent(m[2] ?? "") else { return false }
            self.filter.modifiedAfter = self.dates.ago(boundedCount(count), component)
            return true
        }
        consume("\\b(?:(?:in|within|during|from|over|for)\\s+)?(?:the\\s+)?(?:last|past|previous)\\s+\(num)\\s+\(unit)\\b") { m in
            guard let count = Self.number(m[1]), let component = Self.timeComponent(m[2] ?? "") else { return false }
            self.filter.modifiedAfter = self.dates.ago(boundedCount(count), component)
            return true
        }
        consume("\\b\(num)\\s+\(unit)\\s+old\\b") { m in
            guard let count = Self.number(m[1]), let component = Self.timeComponent(m[2] ?? "") else { return false }
            self.filter.modifiedBefore = self.dates.ago(boundedCount(count), component)
            return true
        }
        consume("\\b\(num)\\s+\(unit)\\s+ago\\b") { m in
            guard let count = Self.number(m[1]), let component = Self.timeComponent(m[2] ?? "") else { return false }
            self.setDates(self.dates.unit(containing: boundedCount(count), component))
            return true
        }
        // Rolling: "in the last week", "past month". Calendar: "last week", "this month".
        consume("\\b(?:(?:in|within|during|over)\\s+the\\s+(?:last|past)|past)\\s+(day|week|month|year)\\b") { m in
            guard let component = Self.timeComponent(m[1] ?? "") else { return false }
            self.filter.modifiedAfter = self.dates.ago(1, component)
            return true
        }
        consume("\\b(?:last|previous)\\s+(week|month|year)\\b") { m in
            self.setDates(self.dates.previous(Self.calendarUnit(m[1] ?? "")))
            return true
        }
        consume("\\b(?:this|current)\\s+(week|month|year)\\b") { m in
            self.setDates(self.dates.current(Self.calendarUnit(m[1] ?? "")))
            return true
        }
        consume("\\btoday\\b") { _ in self.setDates(self.dates.today()); return true }
        consume("\\byesterday\\b") { _ in self.setDates(self.dates.yesterday()); return true }
        consume("\\b(?:(on|last|this|since)\\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)s?\\b") { m in
            guard let index = Self.weekdays.firstIndex(of: m[2] ?? "") else { return false }
            let range = self.dates.weekday(index + 1, strictlyBefore: m[1] == "last")
            if m[1] == "since" { self.filter.modifiedAfter = range.0 } else { self.setDates(range) }
            return true
        }
        // Two ISO dates make one range ("between 2025-03-03 and 2025-04-09", "from … to …"); before single dates.
        consume("\\b(?:between|from)\\s+(\\d{4})-(\\d{1,2})-(\\d{1,2})\\s+(?:and|to|-)\\s+(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b") { m in
            let v = (1...6).compactMap { m[$0].flatMap(Int.init) }
            guard v.count == 6 else { return false }
            self.setDates((self.dates.day(year: v[0], month: v[1], day: v[2]).0, self.dates.day(year: v[3], month: v[4], day: v[5]).1))
            return true
        }
        consume("\\b(before|until|till|prior to|after|since|from|on)?\\s*(\\d{4})-(\\d{1,2})-(\\d{1,2})\\b") { m in
            guard let y = Int(m[2] ?? ""), let mo = Int(m[3] ?? ""), let d = Int(m[4] ?? "") else { return false }
            self.apply(m[1], self.dates.day(year: y, month: mo, day: d))
            return true
        }
        let monthPattern = "(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)"
        // "between march 3 and april 9 2025", "between 2025-03-03 and 2025-04-09"
        consume("\\bbetween\\s+\(monthPattern)\\.?\\s*(\\d{1,2})?(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?\\s+(?:and|to|-)\\s+\(monthPattern)\\.?\\s*(\\d{1,2})?(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?\\b") { m in
            guard let first = Self.months.firstIndex(where: { $0.hasPrefix(m[1] ?? "?") }).map({ $0 + 1 }),
                  let second = Self.months.firstIndex(where: { $0.hasPrefix(m[4] ?? "?") }).map({ $0 + 1 }) else { return false }
            let endYear = m[6].flatMap(Int.init)
            let startYear = m[3].flatMap(Int.init) ?? endYear.map { first <= second ? $0 : $0 - 1 }
            let start = m[2].flatMap(Int.init).map { self.dates.day(year: startYear, month: first, day: $0) } ?? self.dates.month(first, year: startYear)
            let end = m[5].flatMap(Int.init).map { self.dates.day(year: endYear, month: second, day: $0) } ?? self.dates.month(second, year: endYear)
            self.setDates((start.0, end.1))
            return true
        }
        consume("\\b(?:(before|until|till|prior to|after|since|in|from|during|on|of)\\s+)?\(monthPattern)\\.?(?:\\s+(\\d{1,2})(?:st|nd|rd|th)?)?(?:,?\\s+(\\d{4}))?\\b") { m in
            let name = m[2] ?? ""
            guard let month = Self.months.firstIndex(where: { $0.hasPrefix(name) }).map({ $0 + 1 }) else { return false }
            let day = m[3].flatMap(Int.init), year = m[4].flatMap(Int.init)
            // "may" and "march" are also everyday words: need a preposition, a day or a year.
            if ["may", "march", "mar", "jan", "jun", "jul", "aug", "sep", "oct", "nov", "dec", "feb", "apr"].contains(name),
               m[1] == nil, day == nil, year == nil { return false }
            let range = day.map { self.dates.day(year: year, month: month, day: $0) } ?? self.dates.month(month, year: year)
            self.apply(m[1], range)
            return true
        }
        consume("\\b(before|until|till|prior to|after|since|in|from|during|of)\\s+(19\\d{2}|20\\d{2})\\b") { m in
            guard let year = Int(m[2] ?? "") else { return false }
            self.apply(m[1], self.dates.year(year))
            return true
        }
        consume("\\b(recent|recently|lately|latest|newest)\\b") { _ in
            if self.filter.modifiedAfter == nil, self.filter.modifiedBefore == nil { self.filter.modifiedAfter = self.dates.ago(7, .day) }
            return true
        }
    }

    private func setDates(_ range: (Date?, Date?)) {
        filter.modifiedAfter = range.0
        filter.modifiedBefore = range.1
    }

    /// A range with an optional preposition: before X, after X, since X, or (in/on/from) within X.
    private func apply(_ preposition: String?, _ range: (Date?, Date?)) {
        switch preposition {
        case "before", "until", "till", "prior to": filter.modifiedBefore = range.0
        case "after": filter.modifiedAfter = range.1
        case "since": filter.modifiedAfter = range.0
        default: setDates(range)
        }
    }

    // MARK: Kinds

    static let kindAliases: [String: SearchFilter.Kind] = [
        "folder": .folder, "folders": .folder, "dir": .folder, "directory": .folder, "document": .document, "documents": .document,
        "doc": .document, "docs": .document, "pdf": .pdf, "pdfs": .pdf, "text": .text, "image": .image, "images": .image,
        "photo": .image, "photos": .image, "picture": .image, "pictures": .image, "movie": .movie, "movies": .movie, "video": .movie,
        "videos": .movie, "audio": .audio, "music": .audio, "archive": .archive, "archives": .archive, "code": .code,
        "spreadsheet": .spreadsheet, "spreadsheets": .spreadsheet, "presentation": .presentation, "presentations": .presentation,
        "app": .application, "apps": .application, "application": .application, "applications": .application,
        "diskimage": .diskImage, "dmg": .diskImage,
        "book": .book, "books": .book, "ebook": .book, "ebooks": .book, "comic": .comic, "comics": .comic,
    ]

    private func kindsPass() {
        consume("\\bscreen\\s*shots?\\b") { _ in
            self.filter.kinds.insert(.image)
            self.addName("Screenshot")
            return true
        }
        consume("\\bscreen\\s+recordings?\\b") { _ in
            self.filter.kinds.insert(.movie)
            self.addName("Screen Recording")
            return true
        }
        let extensionGroups: [(String, [String])] = [
            ("\\bword\\s+(?:documents?|docs?|files?)\\b", ["doc", "docx"]),
            ("\\bexcel(?:\\s+(?:files?|sheets?|spreadsheets?|workbooks?))?\\b", ["xls", "xlsx"]),
            ("\\b(?:power\\s*points?|ppts?)\\b", ["ppt", "pptx"]),
            ("\\bkeynotes?\\b", ["key"]),
            ("\\b(?:pages)\\s+(?:files?|documents?|docs?)\\b", ["pages"]),
            ("\\b(?:numbers)\\s+(?:files?|spreadsheets?|sheets?)\\b", ["numbers"]),
            ("\\b(?:swift)\\s+(?:files?|code|sources?)\\b", ["swift"]),
            ("\\b(?:python)\\s+(?:files?|code|scripts?|sources?)\\b", ["py"]),
            ("\\b(?:javascript|js)\\s+(?:files?|code|sources?)\\b", ["js", "mjs"]),
            ("\\b(?:typescript|ts)\\s+(?:files?|code|sources?)\\b", ["ts", "tsx"]),
            ("\\b(?:markdown)(?:\\s+(?:files?|notes?|docs?))?\\b", ["md", "markdown"]),
            ("\\b(?:jpe?gs?)\\b", ["jpg", "jpeg"]),
            ("\\b(?:tiffs?|tifs?)\\b", ["tif", "tiff"]),
            ("\\b(?:ya?mls?)\\b", ["yaml", "yml"]),
            ("\\b(?:html?)(?:\\s+files?)?\\b", ["html", "htm"]),
        ]
        for (pattern, extensions) in extensionGroups {
            consume(pattern) { _ in
                self.filter.extensions.formUnion(extensions)
                return true
            }
        }
        consume("(?:^|\\s)\\.?(png|heic|gif|svg|webp|mp4|mov|m4v|mkv|avi|mp3|wav|m4a|aac|flac|csv|tsv|json|xml|xlsx|xls|docx|pptx|txt|rtf|epub|psd|sketch|zip|rar|7z|tar|gz|dmg|iso|pkg|ics|vcf|srt)s?(?:\\s+files?)?\\b") { m in
            self.filter.extensions.insert(m[1] ?? "")
            return true
        }
        let kindWords: [(String, SearchFilter.Kind)] = [
            ("\\b(?:comic\\s+books?|comics?)\\b", .comic),
            ("\\b(?:books?|ebooks?)\\b", .book),
            ("\\b(?:disk\\s+images?|installers?)\\b", .diskImage),
            ("\\b(?:source\\s+code|source\\s+files?|code\\s+files?|code|scripts?)\\b", .code),
            ("\\b(?:text\\s+files?|plain\\s+text|txt\\s+files?)\\b", .text),
            ("\\bpdfs?\\b", .pdf),
            ("\\b(?:images?|photos?|pictures?|pics|imgs?|graphics|wallpapers?)\\b", .image),
            ("\\b(?:videos?|movies?|films?|clips?|footage)\\b", .movie),
            ("\\b(?:audio|music|songs?|tracks?|podcasts?|sounds?|voice\\s+memos?|recordings?)\\b", .audio),
            ("\\b(?:spreadsheets?|sheets|workbooks?)\\b", .spreadsheet),
            ("\\b(?:presentations?|slides?|slide\\s+decks?|decks?)\\b", .presentation),
            ("\\b(?:archives?|zips?|zip\\s+files?|compressed\\s+files?|tarballs?)\\b", .archive),
            ("\\b(?:folders?|directories|directory|dirs?)\\b", .folder),
            ("\\b(?:apps?|applications?|programs?)\\b", .application),
            ("\\b(?:documents?|docs?|paperwork|notes)\\b", .document),
        ]
        for (pattern, kind) in kindWords {
            consume(pattern) { _ in
                self.filter.kinds.insert(kind)
                return true
            }
        }
        // "PDFs" plus "documents" means PDFs: the broader kind adds nothing.
        if filter.kinds.contains(.document), filter.kinds.count > 1 || !filter.extensions.isEmpty,
           filter.kinds.subtracting([.document]).allSatisfy({ [.pdf, .text, .spreadsheet, .presentation].contains($0) }) {
            filter.kinds.remove(.document)
        }
    }

    // MARK: Names and content

    private func names() {
        consume("\\b(?:named|called|titled|with\\s+(?:the\\s+)?name|whose\\s+name\\s+(?:contains|includes|has)|name\\s+(?:contains|containing|includes|including|has)|(?:starting|beginning)\\s+with)\\s+(\"[^\"]+\"|'[^']+'|\\S+)") { m in
            self.addName(m.originalGroup(1))
            return true
        }
    }

    private func content() {
        let lead = "(?:about|containing|contains|mentioning|mentions?|regarding|concerning|related\\s+to|on\\s+the\\s+(?:topic|subject)\\s+of|that\\s+(?:mention|mentions|talk\\s+about|discuss|discusses|say|says|contain|contain|contains)|which\\s+(?:mention|mentions|contain|contains)|with\\s+(?:the\\s+)?(?:text|word|words|phrase))"
        consume("\\b\(lead)\\s+(.+)$") { m in
            guard let topic = Self.cleanTopic(m.originalGroup(1)) else { return false }
            self.filter.contentQuery = topic
            return true
        }
    }

    private func quoted() {
        consume("\"([^\"]+)\"|'([^']+)'") { m in
            self.addName(m.originalGroup(1) ?? m.originalGroup(2))
            return true
        }
    }

    private func addName(_ raw: String?) {
        guard let name = raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), !name.isEmpty,
              !filter.nameContains.contains(name) else { return }
        filter.nameContains.append(name)
    }

    static let fillers: Set<String> = [
        "find", "show", "me", "my", "all", "the", "a", "an", "any", "some", "files", "file", "items", "item", "stuff", "things",
        "from", "of", "in", "on", "at", "with", "that", "which", "who", "are", "were", "is", "was", "i", "have", "has", "had", "and",
        "or", "but", "for", "to", "by", "than", "then", "modified", "changed", "edited", "updated", "saved", "created", "downloaded",
        "added", "opened", "made", "get", "list", "search", "look", "looking", "where", "what", "please", "ones", "those", "these",
        "last", "past", "ago", "old", "since", "before", "after", "between", "during", "within", "under", "over", "bigger",
        "larger", "smaller", "size", "sized", "kind", "type", "named", "called", "everything", "anything", "only", "just", "more",
        "less", "most", "date", "dated", "can", "you", "give", "need", "want", "every", "whose", "mb", "gb", "kb", "it", "them",
        "they", "there", "here", "around", "about", "like", "than", "least", "new", "newer", "older", "s",
    ]

    private func collectLeftovers() {
        let words = (text as String).split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-_")) }
            .filter { !$0.isEmpty && !Self.fillers.contains($0) && !Terms.stopwords.contains($0) }
        leftovers = Array(NSOrderedSet(array: words)) as? [String] ?? words
    }

    /// A topic phrase without trailing filler ("invoices from" → "invoices").
    static func cleanTopic(_ raw: String?) -> String? {
        guard var words = raw?.split(separator: " ").map(String.init) else { return nil }
        while let last = words.last, fillers.contains(last.lowercased()) || Terms.stopwords.contains(last.lowercased()) { words.removeLast() }
        while let first = words.first, ["the", "a", "an", "my", "our"].contains(first.lowercased()) { words.removeFirst() }
        let topic = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'"))
        return topic.isEmpty ? nil : topic
    }

    // MARK: Helpers

    struct Match {
        let groups: [String?]
        let ranges: [NSRange]
        let original: String

        subscript(index: Int) -> String? { index < groups.count ? groups[index] : nil }

        /// A group with its original capitalisation (names and topics keep their case).
        func originalGroup(_ index: Int) -> String? {
            guard index < ranges.count, ranges[index].location != NSNotFound else { return nil }
            let ns = original as NSString
            guard NSMaxRange(ranges[index]) <= ns.length else { return groups[index] }
            return ns.substring(with: ranges[index])
        }
    }

    /// Calls `handler` for each match; matches it accepts are blanked so later passes don't see them.
    private func consume(_ pattern: String, _ handler: (Match) -> Bool) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let snapshot = text as String
        let matches = regex.matches(in: snapshot, range: NSRange(location: 0, length: text.length))
        // The working copy is only lowercased (same UTF-16 length in practice), so ranges also index the original.
        let original = (original as NSString).length == text.length ? self.original : snapshot
        for match in matches {
            let ranges = (0..<match.numberOfRanges).map { match.range(at: $0) }
            let groups = ranges.map { $0.location == NSNotFound ? nil : (snapshot as NSString).substring(with: $0) }
            if handler(Match(groups: groups, ranges: ranges, original: original)) {
                text.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
    }

    static func number(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        let words: [String: Double] = [
            "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
            "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "sixty": 60, "ninety": 90,
            "a couple of": 2, "couple of": 2, "a few": 3, "few": 3, "several": 3,
        ]
        if let value = words[raw] { return value }
        // "1,5" is a decimal; "1,000" is a thousands separator.
        if let comma = raw.firstIndex(of: ","), raw[raw.index(after: comma)...].count == 3 {
            return Double(raw.replacingOccurrences(of: ",", with: ""))
        }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    static func multiplier(_ unit: String) -> Double {
        switch unit.lowercased() {
        case "b", "byte", "bytes": 1
        case "k", "kb", "kilobyte", "kilobytes": 1e3
        case "kib": 1024
        case "m", "mb", "meg", "megs", "megabyte", "megabytes": 1e6
        case "mib": 1_048_576
        case "g", "gb", "gig", "gigs", "gigabyte", "gigabytes": 1e9
        case "gib": 1_073_741_824
        case "t", "tb", "terabyte", "terabytes": 1e12
        case "tib": 1_099_511_627_776
        default: 1e6
        }
    }

    /// "10 MB", "1.5gb", "500 KB" → bytes.
    static func size(_ text: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+(?:[.,]\\d+)?)\\s*\(sizeUnit)?", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let ns = text as NSString
        guard let value = number(ns.substring(with: match.range(at: 1))) else { return nil }
        let unit = match.range(at: 2).location == NSNotFound ? "mb" : ns.substring(with: match.range(at: 2))
        return saturatingInt64(value * multiplier(unit))
    }

    static func timeComponent(_ unit: String) -> Calendar.Component? {
        switch unit.lowercased() {
        case "minute", "minutes", "min", "mins": .minute
        case "hour", "hours", "hr", "hrs", "h": .hour
        case "day", "days", "d": .day
        case "week", "weeks", "wk", "wks", "w": .weekOfYear
        case "month", "months", "mo", "mos", "m": .month
        case "year", "years", "yr", "yrs", "y": .year
        default: nil
        }
    }

    static func calendarUnit(_ word: String) -> Calendar.Component {
        switch word {
        case "week": .weekOfYear
        case "month": .month
        default: .year
        }
    }
}

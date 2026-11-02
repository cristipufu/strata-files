import CoreServices
import Foundation
import Sparkle

/// An installed app, as far as checking it for updates goes: its versions and where its updates come from.
nonisolated struct InstalledApp: Sendable, Equatable {
    /// Where an app's updates come from.
    nonisolated enum Source: Sendable, Equatable {
        /// A Sparkle feed named in its Info.plist (SUFeedURL), like Strata's own.
        case sparkle(URL)
        /// A feed that isn't a secure web address (plain HTTP, or one on this Mac): it isn't read.
        case refusedFeed
        /// The Mac App Store, by its store ID when Spotlight knows it. iPhone and iPad apps are App Store apps too.
        case appStore(id: Int?)
        /// Apple's apps that come with macOS: Software Update.
        case macOS
        /// Its own updater: Sparkle set up in code (`hasSparkle`), or something Strata can't see into.
        case itself(hasSparkle: Bool)
        /// Its Info.plist is missing or can't be read.
        case unreadable
    }

    let url: URL
    let name: String
    let bundleID: String?
    /// What people see: "2.4.1".
    let version: String?
    /// CFBundleVersion, what Sparkle compares.
    let build: String?
    let source: Source
    /// The Strata that's running, which its own updater installs.
    var isThisStrata = false

    /// Reads the bundle at `url`. Info.plist is read from disk each time (Bundle caches it, and an app updated since would
    /// still show its old version), and only when it's a regular file of a sensible size: a bundle is someone else's
    /// folder, and its "Info.plist" could be a pipe or a link to an endless device.
    static func read(_ url: URL) -> InstalledApp {
        var app = readBundle(url)
        app.isThisStrata = AppUpdatesController.isThisCopyOfStrata(url)
        return app
    }

    private static func readBundle(_ url: URL) -> InstalledApp {
        let name = FileManager.default.displayName(atPath: url.path)
        // iPhone and iPad apps on a Mac keep their own bundle inside a wrapper.
        let wrapped = url.appending(components: "WrappedBundle", "Info.plist")
        let isWrapped = FileManager.default.fileExists(atPath: url.appending(component: "Wrapper").path)
        guard let info = plist(at: isWrapped ? wrapped : url.appending(components: "Contents", "Info.plist")) else {
            return InstalledApp(url: url, name: name, bundleID: nil, version: nil, build: nil, source: .unreadable)
        }
        let bundleID = info["CFBundleIdentifier"] as? String
        return InstalledApp(url: url, name: name, bundleID: bundleID,
                            version: (info["CFBundleShortVersionString"] as? String).flatMap { Versions.clean($0) },
                            build: (info["CFBundleVersion"] as? String).flatMap { Versions.clean($0) },
                            source: isWrapped ? .appStore(id: appStoreID(url)) : source(of: url, info: info, bundleID: bundleID))
    }

    static let maximumInfoSize = 1 << 20

    private static func plist(at url: URL) -> [String: Any]? {
        guard let (data, truncated) = try? TextFile.readPrefix(url, limit: maximumInfoSize), !truncated,
              BinaryPropertyListBudget.permitsDecoding(data, limit: 8 * maximumInfoSize) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func source(of url: URL, info: [String: Any], bundleID: String?) -> Source {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.appending(components: "Contents", "_MASReceipt", "receipt").path) {
            return .appStore(id: appStoreID(url))
        }
        // What macOS itself installs (Safari lives in /Applications but comes with macOS too).
        let path = url.resolvingSymlinksInPath().path
        if ["/System/Applications/", "/System/Library/", "/System/Cryptexes/"].contains(where: path.hasPrefix)
            || ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(bundleID ?? "") {
            return .macOS
        }
        if let text = info["SUFeedURL"] as? String {
            guard let feed = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), FeedAddress.isAllowed(feed) else {
                return .refusedFeed
            }
            return .sparkle(feed)
        }
        let sparkle = fileManager.fileExists(atPath: url.appending(components: "Contents", "Frameworks", "Sparkle.framework").path)
        return .itself(hasSparkle: sparkle)
    }

    /// The App Store's ID for the app, which Spotlight records for apps installed from the store.
    private static func appStoreID(_ url: URL) -> Int? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let value = MDItemCopyAttribute(item, "kMDItemAppStoreAdamID" as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }
}

/// Which feed addresses are read: HTTPS on another machine. A feed is an address an app's bundle names, so Strata never
/// sends a request to this Mac itself (localhost, loopback and link-local addresses) on its say-so.
///
/// Hosts are judged the way the network will see them: numbers in any form the resolver takes ("127.1", "2130706433",
/// "0x7f.0.0.1"), with a trailing dot or an IPv6 zone, and, right before each request and redirect, every address the
/// name resolves to (a name can point at 127.0.0.1).
///
/// A name that resolves elsewhere for that check and to this Mac a moment later (DNS rebinding) still gets nowhere:
/// requests are HTTPS only, with App Transport Security's certificate checks and no exceptions, so a service on this Mac
/// would have to present a trusted certificate for the feed's own name. The connection fails during the TLS handshake,
/// before any request is sent, and requests carry no cookies or credentials anyway.
nonisolated enum FeedAddress {
    /// The address as written: HTTPS, and not this Mac.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = host(of: url) else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if let address = literal(host) { return !isLocal(address) }
        return true
    }

    /// `isAllowed`, and none of the addresses its name resolves to is this Mac. Resolving blocks, so it runs off the main
    /// thread (in a check, or in URLSession's delegate queue for redirects).
    static func isSafeToFetch(_ url: URL) -> Bool {
        guard isAllowed(url), let host = host(of: url) else { return false }
        return literal(host) != nil || !resolvesToThisMac(host)
    }

    /// Whether any address `host` resolves to is this Mac's.
    static func resolvesToThisMac(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        // A name that doesn't resolve is left to the request, which fails on its own.
        guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if isLocal(.v4(v4)) { return true }
            case AF_INET6:
                let v6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if isLocal(.v6(v6)) { return true }
            default:
                continue
            }
        }
        return false
    }

    nonisolated enum Address {
        case v4(in_addr)
        case v6(in6_addr)
    }

    /// The host without brackets, an IPv6 zone or trailing dots, lowercased.
    private static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// The host as a numeric address, read as leniently as the resolver reads it (inet_aton takes "127.1" and hex).
    static func literal(_ host: String) -> Address? {
        var v4 = in_addr()
        if inet_aton(host, &v4) == 1 { return .v4(v4) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return .v6(v6) }
        return nil
    }

    /// 0.0.0.0/8, 127.0.0.0/8 and 169.254.0.0/16; ::, ::1, fe80::/10, and those IPv4 addresses written as IPv6
    /// (::ffff:127.0.0.1, ::127.0.0.1).
    static func isLocal(_ address: Address) -> Bool {
        switch address {
        case .v4(let v4):
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return bytes[0] == 0 || bytes[0] == 127 || bytes[0] == 10
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        case .v6(let v6):
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) { return true }
            if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
            let embedsV4 = bytes[0..<10].allSatisfy { $0 == 0 } && ((bytes[10] == 0xff && bytes[11] == 0xff) || (bytes[10] == 0 && bytes[11] == 0))
            guard embedsV4 else { return false }
            return isLocal(.v4(in_addr(s_addr: bytes[12..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })))
        }
    }
}

/// What a check found.
nonisolated enum AppUpdateResult: Sendable, Equatable {
    case upToDate
    /// A newer version; `page` is where to read about it or get it (its notes, or the App Store page).
    case available(version: String, page: URL?)
    /// The newest version needs a newer macOS than this Mac's.
    case needsNewerMacOS(version: String, macOS: String)
    /// The App Store's lookup doesn't list it (Apple's own free apps, iPhone and iPad apps): its Updates page will know.
    case askAppStore
    /// Updated by macOS's Software Update.
    case withMacOS
    /// The app updates itself (`hasSparkle`) or Strata can't tell how it's updated.
    case itself(hasSparkle: Bool)
    case failed(String)

    /// Whether Strata found out if there's something newer.
    var wasChecked: Bool {
        switch self {
        case .upToDate, .available, .needsNewerMacOS: true
        default: false
        }
    }
}

/// Checks apps for updates. Only when you ask: each check reads the app's own update feed, and the App Store is asked
/// about its apps all at once; nothing else is sent.
nonisolated enum AppUpdateCheck {
    /// Reads every bundle, off the main thread.
    @concurrent static func read(_ urls: [URL]) async -> [InstalledApp] {
        urls.map(InstalledApp.read)
    }

    @concurrent static func check(_ app: InstalledApp, store: StoreAnswers) async -> AppUpdateResult {
        switch app.source {
        case .sparkle(let feed):
            return await checkFeed(feed, app: app)
        case .refusedFeed:
            return .failed(String(localized: "Its update feed isn’t a secure web address, so Strata doesn’t read it.",
                                  comment: "Checking an app for updates: why it wasn't checked"))
        case .appStore(let id):
            guard let id, let listing = store.listings[id] else {
                return store.failure.map(AppUpdateResult.failed) ?? .askAppStore
            }
            guard Versions.compare(listing.version, app.version ?? "0") == .orderedDescending else { return .upToDate }
            if let needs = listing.minimumOS, Versions.compare(needs, Versions.system) == .orderedDescending {
                return .needsNewerMacOS(version: listing.version, macOS: needs)
            }
            return .available(version: listing.version, page: listing.storePage)
        case .macOS:
            return .withMacOS
        case .itself(let hasSparkle):
            return .itself(hasSparkle: hasSparkle)
        case .unreadable:
            return .failed(String(localized: "Strata can’t read this app’s information.", comment: "Checking an app for updates: its Info.plist is missing or unreadable"))
        }
    }

    // MARK: - Sparkle feeds

    private static func checkFeed(_ feed: URL, app: InstalledApp) async -> AppUpdateResult {
        let data: Data
        do {
            data = try await fetch(feed)
        } catch {
            return .failed(failure(error))
        }
        let items = Appcast.parse(data, feed: feed)
        guard !items.isEmpty else {
            return .failed(String(localized: "Its update feed doesn’t list any versions.", comment: "Checking an app for updates: the feed was empty or unreadable"))
        }
        return evaluate(items, installedBuild: app.build ?? app.version ?? "0", system: Versions.system)
    }

    /// The newest version this Mac can run, compared with the installed one the way Sparkle compares them.
    static func evaluate(_ items: [Appcast.Item], installedBuild: String, system: String) -> AppUpdateResult {
        // Betas live on channels, and other systems' builds say so; neither is for this Mac.
        let candidates = items.filter { $0.channel == nil && ($0.os == nil || $0.os == "macos") }
            .sorted { Versions.compare($0.version, $1.version) == .orderedDescending }
        guard let newest = candidates.first,
              Versions.compare(newest.version, installedBuild) == .orderedDescending else { return .upToDate }
        let runnable = candidates.first { item in
            (item.minimumSystemVersion.map { Versions.compare($0, system) != .orderedDescending } ?? true)
                && (item.maximumSystemVersion.map { Versions.compare($0, system) != .orderedAscending } ?? true)
        }
        if let runnable, Versions.compare(runnable.version, installedBuild) == .orderedDescending {
            return .available(version: runnable.displayVersion, page: runnable.page)
        }
        if let needs = newest.minimumSystemVersion, Versions.compare(needs, system) == .orderedDescending {
            return .needsNewerMacOS(version: newest.displayVersion, macOS: needs)
        }
        return .upToDate
    }

    // MARK: - App Store

    /// The App Store's listings for a check's App Store apps, by store ID. `failure` says why some couldn't be looked up.
    nonisolated struct StoreAnswers: Sendable {
        var listings: [Int: StoreListing] = [:]
        var failure: String?
    }

    /// Looks up every App Store app in one request per store region (the lookup service allows about 20 a minute, so
    /// not one per app): the Mac's region first, then the US store for apps not sold there.
    @concurrent static func lookUpAppStore(_ apps: [InstalledApp]) async -> StoreAnswers {
        var wanted: [Int] = []
        for app in apps { if case .appStore(let id?) = app.source, !wanted.contains(id) { wanted.append(id) } }
        var answers = StoreAnswers()
        guard !wanted.isEmpty else { return answers }
        let local = Locale.current.region?.identifier.uppercased()
        let regions = [local].compactMap { $0 }.filter { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } } + ["US"]
        for region in regions.reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            let missing = wanted.filter { answers.listings[$0] == nil }
            guard !missing.isEmpty else { break }
            for start in stride(from: 0, to: missing.count, by: 100) {
                let ids = missing[start..<min(start + 100, missing.count)]
                var components = URLComponents(string: "https://itunes.apple.com/lookup")!
                components.queryItems = [URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
                                         URLQueryItem(name: "entity", value: "desktopSoftware"),
                                         URLQueryItem(name: "country", value: region)]
                do {
                    let data = try await fetch(components.url!)
                    answers.listings.merge(StoreListing.parse(data)) { first, _ in first }
                    answers.failure = nil
                } catch FetchError.status(let code) where (400..<500).contains(code) {
                    // Turned away in this region: the next one may answer.
                    answers.failure = failure(FetchError.status(code))
                } catch {
                    answers.failure = failure(error)
                    return answers
                }
            }
        }
        return answers
    }

    /// The App Store's answer for one Mac app.
    nonisolated struct StoreListing: Sendable, Equatable {
        let version: String
        let minimumOS: String?
        /// Its page in the App Store app.
        let storePage: URL?

        /// The Mac apps in a lookup's results, by store ID (an iPhone app with the same ID isn't one).
        static func parse(_ data: Data) -> [Int: StoreListing] {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return [:] }
            var listings: [Int: StoreListing] = [:]
            for result in results where result["kind"] as? String == "mac-software" {
                guard let id = result["trackId"] as? Int, let version = (result["version"] as? String).flatMap({ Versions.clean($0) }) else { continue }
                listings[id] = StoreListing(version: version, minimumOS: (result["minimumOsVersion"] as? String).flatMap { Versions.clean($0) },
                                            storePage: URL(string: "macappstore://apps.apple.com/app/id\(id)"))
            }
            return listings
        }
    }

    // MARK: - Fetching

    /// No cookies, no cache, nothing stored: each check is a plain request for one document.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: SafeRedirects(), delegateQueue: nil)
    }()

    /// A feed is a few kilobytes; a big app's, with every version's notes, a few hundred. Nothing near this is a feed.
    static let maximumSize = 8 << 20

    nonisolated enum FetchError: Error {
        case status(Int)
        case tooLarge
        /// The address leads to this Mac.
        case refused
    }

    private static func fetch(_ url: URL) async throws -> Data {
        guard FeedAddress.isSafeToFetch(url) else { throw FetchError.refused }
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/xml, application/json;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw FetchError.status(http.statusCode) }
        if response.expectedContentLength > maximumSize { throw FetchError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumSize { throw FetchError.tooLarge }
        }
        return data
    }

    private static func failure(_ error: Error) -> String {
        switch error {
        case FetchError.status(let code) where (300..<400).contains(code):
            // A redirect Strata didn't follow (see SafeRedirects).
            return String(localized: "Its update feed moved to an address that isn’t secure.", comment: "Checking an app for updates: a redirect to plain HTTP or to this Mac")
        case FetchError.status(let code):
            return String(localized: "Its update server answered with an error (\(code)).", comment: "Checking an app for updates; the placeholder is an HTTP status code")
        case FetchError.refused:
            return String(localized: "Its update feed isn’t a secure web address, so Strata doesn’t read it.",
                          comment: "Checking an app for updates: why it wasn't checked")
        case FetchError.tooLarge:
            return String(localized: "Its update feed is too large to be one.", comment: "Checking an app for updates: the feed was suspiciously big")
        case let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost:
            return String(localized: "You’re offline.", comment: "Checking an app for updates: no internet connection")
        case let error as URLError where error.code == .timedOut:
            return String(localized: "Its update server didn’t answer in time.", comment: "Checking an app for updates: timed out")
        default:
            return String(localized: "Its update server couldn’t be reached.", comment: "Checking an app for updates: any other network error")
        }
    }
}

/// Redirects are followed only to addresses a feed could have named itself: HTTPS, not this Mac.
private nonisolated final class SafeRedirects: NSObject, URLSessionTaskDelegate {
    // The completion-handler form: the async one crashes this compiler.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(FeedAddress.isSafeToFetch) == true ? request : nil)
    }
}

// MARK: - Appcasts

/// Reads a Sparkle appcast the way Sparkle does: each `/rss/channel/item`'s own children (not what's nested in them, like
/// an informational update's list of versions), the enclosure's attributes before the item's elements.
nonisolated enum Appcast {
    nonisolated struct Item: Sendable, Equatable {
        /// What Sparkle compares: the build (CFBundleVersion).
        var version: String
        var shortVersion: String?
        var minimumSystemVersion: String?
        var maximumSystemVersion: String?
        var channel: String?
        var os: String?
        /// Where to read about it: the full release notes, its notes, or the item's link (HTTPS only).
        var page: URL?

        var displayVersion: String { shortVersion ?? version }
    }

    private static let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    static func parse(_ data: Data, feed: URL? = nil) -> [Item] {
        // Never load anything a feed points at while reading it.
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let nodes = try? document.nodes(forXPath: "/rss/channel/item") else { return [] }
        return nodes.compactMap { item(from: $0, feed: feed) }
    }

    /// A node's name, with Sparkle's elements and attributes always spelled `sparkle:`, whatever the feed's prefix.
    private static func name(_ node: XMLNode) -> String? {
        if node.uri == sparkleNamespace, let local = node.localName { return "sparkle:" + local }
        return node.name
    }

    private static func item(from node: XMLNode, feed: URL?) -> Item? {
        var fields: [String: String] = [:]
        var enclosure: [String: String] = [:]
        for child in node.children ?? [] where child.kind == .element {
            guard let key = name(child), fields[key] == nil else { continue }
            if key == "enclosure", enclosure.isEmpty, let element = child as? XMLElement {
                for attribute in element.attributes ?? [] {
                    if let attributeName = name(attribute), let value = attribute.stringValue { enclosure[attributeName] = value }
                }
            }
            // Only text: an element holding others (an informational update's versions) isn't one value.
            if child.children?.allSatisfy({ $0.kind == .text }) ?? true,
               let value = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                fields[key] = value
            }
        }
        guard let version = (enclosure["sparkle:version"] ?? fields["sparkle:version"]).flatMap({ Versions.clean($0) }) else { return nil }
        let page = ["sparkle:fullReleaseNotesLink", "sparkle:releaseNotesLink", "link"].lazy
            .compactMap { fields[$0].flatMap { URL(string: $0, relativeTo: feed)?.absoluteURL } }
            .first { $0.scheme?.lowercased() == "https" }
        return Item(version: version,
                    shortVersion: (enclosure["sparkle:shortVersionString"] ?? fields["sparkle:shortVersionString"]).flatMap { Versions.clean($0) },
                    minimumSystemVersion: fields["sparkle:minimumSystemVersion"].flatMap { Versions.clean($0) },
                    maximumSystemVersion: fields["sparkle:maximumSystemVersion"].flatMap { Versions.clean($0) },
                    channel: fields["sparkle:channel"], os: enclosure["sparkle:os"]?.lowercased(), page: page)
    }
}

// MARK: - Versions

/// Versions compared by Sparkle's own rules (its standard comparator), so a check agrees with what the app's updater
/// will find.
nonisolated enum Versions {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        SUStandardVersionComparator().compareVersion(a, toVersion: b)
    }

    /// This Mac's macOS as Sparkle spells it: "26.1.0".
    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// A version as shown: one line, no control characters, at most 32 characters (a feed is someone else's text).
    static func clean(_ text: String) -> String? {
        let line = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(32))
    }
}

import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct AppUpdateTests {
    // MARK: Versions (Sparkle's comparator)

    @Test func versionsCompareLikeSparkle() {
        #expect(Versions.compare("1.10", "1.9") == .orderedDescending)
        #expect(Versions.compare("1.0", "1.0b2") == .orderedDescending)
        #expect(Versions.compare("2", "10") == .orderedAscending)
        // Sparkle 2 balances missing parts and stops at a dash.
        #expect(Versions.compare("1.0", "1.0.0") == .orderedSame)
        #expect(Versions.compare("26.1", "26.1.0") == .orderedSame)
        #expect(Versions.compare("1.5.5-335d3e2", "1.5.5-a655360") == .orderedSame)
    }

    @Test func versionsAreCleanedForShowing() {
        #expect(Versions.clean("  2.4.1\n") == "2.4.1")
        #expect(Versions.clean("1.0\u{7}beta") == "1.0beta")
        #expect(Versions.clean(String(repeating: "9", count: 100))?.count == 32)
        #expect(Versions.clean(" \n ") == nil)
    }

    // MARK: Appcasts

    static let feed = """
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:sp="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>X</title>
    <item><title>3.0 beta</title><sp:channel>beta</sp:channel><sp:version>300</sp:version><enclosure url="https://x/3.zip"/></item>
    <item><title>2.6 Windows</title><enclosure url="https://x/w.zip" sp:version="260" sp:os="windows"/></item>
    <item><title>2.5 needs 99</title><sp:version>250</sp:version><sp:shortVersionString>2.5</sp:shortVersionString><sp:minimumSystemVersion>99.0</sp:minimumSystemVersion></item>
    <item><title>2.4 informational</title><sp:version>240</sp:version>
      <sp:informationalUpdate><sp:version>230</sp:version><sp:version>235</sp:version></sp:informationalUpdate>
      <sp:fullReleaseNotesLink>notes/2.4.html</sp:fullReleaseNotesLink></item>
    <item><title>2.3</title><sp:version>999</sp:version>
      <enclosure url="https://x/2.3.zip" sp:version="230" sp:shortVersionString="2.3"/>
      <sp:deltas><enclosure url="https://x/d.delta" sp:version="230" sp:deltaFrom="220"/></sp:deltas></item>
    <item><title>2.2</title><sp:version><![CDATA[220]]></sp:version><sp:releaseNotesLink>http://x/insecure</sp:releaseNotesLink></item>
    </channel></rss>
    """

    @Test func appcastsAreReadLikeSparkleReadsThem() throws {
        let items = Appcast.parse(Data(Self.feed.utf8), feed: URL(string: "https://example.com/appcast.xml"))
        #expect(items.map(\.version) == ["300", "260", "250", "240", "230", "220"])
        // An informational update's list of versions isn't the item's own version.
        let informational = try #require(items.first { $0.version == "240" })
        #expect(informational.page?.absoluteString == "https://example.com/notes/2.4.html")
        // The enclosure's attributes come before the item's elements.
        #expect(items.first { $0.version == "230" }?.shortVersion == "2.3")
        #expect(items.first { $0.version == "220" }?.page == nil)
        #expect(items.first { $0.version == "260" }?.os == "windows")
        #expect(items.first { $0.version == "300" }?.channel == "beta")
    }

    @Test func theNewestVersionThisMacCanRunWins() {
        let items = Appcast.parse(Data(Self.feed.utf8))
        #expect(AppUpdateCheck.evaluate(items, installedBuild: "230", system: "26.0.0") == .available(version: "240", page: nil))
        #expect(AppUpdateCheck.evaluate(items, installedBuild: "240", system: "26.0.0") == .needsNewerMacOS(version: "2.5", macOS: "99.0"))
        #expect(AppUpdateCheck.evaluate(items, installedBuild: "250", system: "26.0.0") == .upToDate)
        #expect(AppUpdateCheck.evaluate(items, installedBuild: "999", system: "26.0.0") == .upToDate)
    }

    @Test func aMaximumSystemVersionIncludesThatVersion() {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>2</sparkle:version><sparkle:maximumSystemVersion>26.1</sparkle:maximumSystemVersion></item></channel></rss>
        """
        #expect(AppUpdateCheck.evaluate(Appcast.parse(Data(feed.utf8)), installedBuild: "1", system: "26.1.0") == .available(version: "2", page: nil))
    }

    @Test func externalEntitiesAreNeverRead() {
        let feed = """
        <?xml version="1.0"?><!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/hosts">]>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>&x;</sparkle:version></item></channel></rss>
        """
        #expect(!Appcast.parse(Data(feed.utf8)).contains { $0.version.contains("localhost") })
        #expect(Appcast.parse(Data("not xml".utf8)).isEmpty)
    }

    // MARK: App Store

    @Test func onlyMacListingsCount() {
        let json = #"{"results":[{"kind":"mac-software","trackId":1,"version":"2.0","minimumOsVersion":"26.0"},{"kind":"software","trackId":2,"version":"9.0"}]}"#
        let listings = AppUpdateCheck.StoreListing.parse(Data(json.utf8))
        #expect(listings.keys.sorted() == [1])
        #expect(listings[1] == .init(version: "2.0", minimumOS: "26.0", storePage: URL(string: "macappstore://apps.apple.com/app/id1")))
    }

    // MARK: Feed addresses

    @Test func feedsAreHTTPSAndNotThisMac() {
        for allowed in ["https://example.com/a.xml", "https://[2001:db8::1]/a.xml"] {
            #expect(FeedAddress.isAllowed(URL(string: allowed)!), "\(allowed)")
        }
        for refused in ["https://10.0.0.5/a.xml", "https://172.16.0.1/", "https://172.31.255.255/", "https://192.168.1.1/",
                        "https://[fc00::1]/", "https://[fdff::1]/", "https://[::ffff:192.168.1.1]/", "http://example.com/a.xml", "https://localhost/a.xml", "https://127.0.0.1/a.xml", "https://169.254.169.254/",
                        "https://[::1]/a.xml", "https://[fe80::1]/a.xml", "https://[::ffff:127.0.0.1]/", "https://0.0.0.0/", "file:///etc/hosts",
                        // Spellings the resolver reads as this Mac.
                        "https://127.1/", "https://2130706433/", "https://0x7f.0.0.1/", "https://0177.0.0.1/", "https://localhost./",
                        "https://127.0.0.1./", "https://LOCALHOST/", "https://[fe80::1%25en0]/", "https://[::127.0.0.1]/", "https://[::ffff:7f00:1]/"] {
            #expect(!FeedAddress.isAllowed(URL(string: refused)!), "\(refused)")
        }
    }

    @Test func namesThatResolveToThisMacAreRefused() {
        // localhost resolves from /etc/hosts, without the network.
        #expect(FeedAddress.resolvesToThisMac("localhost"))
        #expect(!FeedAddress.resolvesToThisMac("203.0.113.7"))
        #expect(FeedAddress.isSafeToFetch(URL(string: "https://203.0.113.7/a.xml")!))
    }

    // MARK: Bundles

    @Test func bundlesAreReadSafely() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "strata-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, _ info: [String: String]?) throws -> URL {
            let url = root.appending(path: "\(name).app")
            try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
            if let info {
                let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                try data.write(to: url.appending(path: "Contents/Info.plist"))
            }
            return url
        }
        let feed = try app("Feed", ["CFBundleVersion": "5", "CFBundleShortVersionString": "1.5", "SUFeedURL": "https://example.com/appcast.xml"])
        #expect(InstalledApp.read(feed).source == .sparkle(URL(string: "https://example.com/appcast.xml")!))
        #expect(InstalledApp.read(feed).build == "5")
        let plain = try app("Plain", ["SUFeedURL": "http://example.com/appcast.xml"])
        #expect(InstalledApp.read(plain).source == .refusedFeed)
        #expect(InstalledApp.read(try app("None", ["CFBundleVersion": "1"])).source == .itself(hasSparkle: false))
        #expect(InstalledApp.read(try app("Empty", nil)).source == .unreadable)
        // An Info.plist that's a pipe, or a link to an endless device, isn't read (and doesn't hang).
        let pipe = try app("Pipe", nil)
        #expect(mkfifo(pipe.appending(path: "Contents/Info.plist").path, 0o600) == 0)
        #expect(InstalledApp.read(pipe).source == .unreadable)
        let endless = try app("Endless", nil)
        try FileManager.default.createSymbolicLink(atPath: endless.appending(path: "Contents/Info.plist").path, withDestinationPath: "/dev/zero")
        #expect(InstalledApp.read(endless).source == .unreadable)
    }
}

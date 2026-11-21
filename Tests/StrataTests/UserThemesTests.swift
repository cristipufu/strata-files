import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataTheme

struct UserThemesTests {
    private static let folder = URL(filePath: "/nowhere/Themes", directoryHint: .isDirectory)
    private static let keptFileKey = "colorThemeFile"
    private static let changedSeed = ThemeRGB(red: 0.2, green: 0.5, blue: 0.3)

    private func themes(reading reader: @escaping UserThemes.Reader,
                        besides taken: [ColorTheme] = [.system] + ThemeCatalog.bundled) -> UserThemes {
        UserThemes(folder: Self.folder, besides: taken, reader: reader)
    }

    private func dusk() throws -> ThemeCatalog.File { try ThemeFixture.file(id: "dusk", name: "Dusk", order: 151) }

    private func changedMeadow() throws -> ThemeCatalog.File { try ThemeFixture.file(changing: ["seed": [0.2, 0.5, 0.3]]) }

    /// A valid theme file padded with spaces to `bytes`: whatever follows its closing brace is no part of it.
    private func padded(_ file: ThemeCatalog.File, to bytes: Int) -> ThemeCatalog.File {
        (file.name, file.data + Data(repeating: 0x20, count: bytes - file.data.count))
    }

    /// How often windows were told of a theme change.
    nonisolated private final class Tellings: Sendable {
        private let told = Mutex(0)
        var count: Int { told.withLock { $0 } }
        func tell() { told.withLock { $0 += 1 } }
    }

    /// What each asking about the folder was told, in the order they were told. A class of its own: a task may not
    /// take a lock that is the test's own local.
    nonisolated private final class Answers: Sendable {
        private let told = Mutex<[Bool]>([])
        var all: [Bool] { told.withLock { $0 } }

        /// Adds an answer and says how many there are now.
        func add(_ answer: Bool) -> Int {
            told.withLock { told in
                told.append(answer)
                return told.count
            }
        }
    }

    /// Counts in `told` how often `preferences` tell of a theme change, until the returned observer is removed.
    private func counting(_ told: Tellings, in preferences: Prefs) -> any NSObjectProtocol {
        preferences.notifications.addObserver(forName: .colorThemeChanged, object: nil, queue: nil) { _ in told.tell() }
    }

    @Test func onlyAStoreToldWhereItsFolderIsReadsOne() async throws {
        let folder = ThemeFolderInMemory([try ThemeFixture.file()])
        let themes = UserThemes(besides: [], reader: folder.reader)
        #expect(await themes.read() == false)
        #expect(folder.reads == 0 && themes.themes.isEmpty)
        // The app's own store is told by the executable alone (a Python check sees to that), so it reads none here.
        #expect(await UserThemes.shared.read() == false)
        #expect(UserThemes.shared.themes.isEmpty)
    }

    @Test func theFolderIsReadAwayFromTheMainThreadAndItsThemesJoinTheOthers() async throws {
        let folder = ThemeFolderInMemory([try dusk(), try ThemeFixture.file()])
        let themes = themes(reading: folder.reader)
        #expect(themes.themes.isEmpty && ColorTheme.named("meadow", among: themes) == nil)
        #expect(await themes.read())
        #expect(folder.reads == 1 && !folder.wasReadOnTheMainThread)
        #expect(themes.themes.map(\.rawValue) == ["meadow", "dusk"])
        #expect(ColorTheme.choices(with: themes) == [.system] + ThemeCatalog.bundled + themes.themes)
        #expect(ColorTheme.named("dusk", among: themes)?.title == "Dusk")
        #expect(ColorTheme.named("blue", among: themes) == .blue && ColorTheme.named("system", among: themes) == .system)
        #expect(ColorTheme.named("missing", among: themes) == nil)
        // A folder that holds what was known is nothing to tell anyone of.
        #expect(await themes.read() == false)
        #expect(folder.reads == 2 && themes.themes.map(\.rawValue) == ["meadow", "dusk"])
    }

    @Test func theChosenThemeIsDrawnAtTheNextLaunchBeforeItsFolderIsRead() async throws {
        let preferences = try Prefs.isolated()
        let folder = ThemeFolderInMemory([try changedMeadow(), try dusk()])
        let running = themes(reading: folder.reader)
        #expect(await running.read())
        let meadow = try #require(ColorTheme.named("meadow", among: running))
        let chosen = ColorThemeOptions(palette: meadow, tintsWindow: false)
        chosen.save(in: preferences.defaults, userThemes: running)

        let reopened = try #require(UserDefaults(suiteName: preferences.domainName))
        let relaunched = themes(reading: folder.reader)
        #expect(ColorThemeOptions.read(from: reopened, userThemes: relaunched) == ColorThemeOptions(palette: .system, tintsWindow: false))
        relaunched.rememberChoice(in: reopened)
        let read = ColorThemeOptions.read(from: reopened, userThemes: relaunched)
        #expect(read == chosen && read.palette.seed == Self.changedSeed)
        #expect(relaunched.themes == [meadow])
        #expect(folder.reads == 1)
        // The folder then says what else there is to choose from.
        #expect(await relaunched.read())
        #expect(relaunched.themes.map(\.rawValue) == ["meadow", "dusk"])
        #expect(ColorThemeOptions.read(from: reopened, userThemes: relaunched) == chosen)
        // The suite is its preferences' to remove: they are asked last.
        #expect(preferences.colorThemeOptions(among: relaunched) == chosen)
    }

    @Test func aBundledChoiceKeepsNoCopyAndForgetsAnEarlierOne() async throws {
        let defaults = try Prefs.isolated().defaults
        let file = try ThemeFixture.file()
        let themes = themes(reading: ThemeFolderInMemory([file]).reader)
        #expect(await themes.read())
        let meadow = try #require(ColorTheme.named("meadow", among: themes))
        ColorThemeOptions(palette: meadow).save(in: defaults, userThemes: themes)
        #expect(defaults.data(forKey: Self.keptFileKey) == file.data)
        ColorThemeOptions(palette: .blue).save(in: defaults, userThemes: themes)
        #expect(defaults.object(forKey: Self.keptFileKey) == nil)
        #expect(ColorThemeOptions.read(from: defaults, userThemes: themes).palette == .blue)
    }

    @Test func aKeptCopyIsCheckedLikeAFileOfTheFolderAndNeverRewritten() throws {
        let meadow = try ThemeFixture.file()
        let bundled = try #require(ThemeCatalog.bundled.first)
        let fits = padded(meadow, to: ThemeCatalog.maximumBytes), longer = padded(meadow, to: ThemeCatalog.maximumBytes + 1)
        let refused: [(chosen: String, kept: Any)] = [
            ("meadow", Data("{".utf8)),
            ("meadow", try dusk().data),                                             // another theme's file
            ("meadow", longer.data),
            ("meadow", "not a file"),
            (bundled.rawValue, try ThemeFixture.file(id: bundled.rawValue, name: "Mine").data),    // a bundled ID
            ("meadow", try ThemeFixture.file(name: bundled.title).data),             // a bundled name
            ("meadow", try ThemeFixture.file(name: "System").data),                  // the system's
        ]
        for (chosen, kept) in refused {
            let defaults = try Prefs.isolated().defaults
            defaults.set(chosen, forKey: "colorTheme")
            defaults.set(kept, forKey: Self.keptFileKey)
            let themes = themes(reading: ThemeFolderInMemory().reader)
            themes.rememberChoice(in: defaults)
            #expect(themes.themes.isEmpty, "\(chosen): \(kept)")
            #expect(ColorTheme.named("meadow", among: themes) == nil)
            #expect(defaults.string(forKey: "colorTheme") == chosen)
            #expect((defaults.object(forKey: Self.keptFileKey) as? NSObject) == (kept as? NSObject))
        }
        let defaults = try Prefs.isolated().defaults
        defaults.set("meadow", forKey: "colorTheme")
        defaults.set(fits.data, forKey: Self.keptFileKey)
        let themes = themes(reading: ThemeFolderInMemory().reader)
        themes.rememberChoice(in: defaults)
        #expect(themes.themes.map(\.rawValue) == ["meadow"])
    }

    @Test func onceTheFolderWasAskedAboutTheKeptCopySaysNothing() async throws {
        let defaults = try Prefs.isolated().defaults
        defaults.set("meadow", forKey: "colorTheme")
        defaults.set(try ThemeFixture.file().data, forKey: Self.keptFileKey)
        let themes = themes(reading: ThemeFolderInMemory([try dusk()]).reader)
        #expect(await themes.read())
        themes.rememberChoice(in: defaults)
        #expect(themes.themes.map(\.rawValue) == ["dusk"])
        #expect(ColorThemeOptions.read(from: defaults, userThemes: themes).palette == .system)
    }

    @Test func askedAboutWhileItIsReadTheFolderIsReadOnceMoreAndNoMore() async throws {
        let folder = ThemeFolderInMemory([try ThemeFixture.file()])
        let themes = themes(reading: folder.reader)
        let newer = [try dusk()]
        let answers = Answers()
        let twoWereAnswered = DispatchSemaphore(value: 0)
        // During the first read three more ask. One waits to read once that read has ended; the other two are told
        // at once that nothing is theirs to tell. The first read goes on when two were told: all three have asked by
        // then, whichever came first. No wait here is without an end, so a broken rule fails and holds nothing.
        folder.whileReading { number in
            guard number == 1 else { return }
            folder.hold(newer)
            for _ in 0..<3 {
                Task {
                    if answers.add(await themes.read()) == 2 { twoWereAnswered.signal() }
                }
            }
            _ = twoWereAnswered.wait(timeout: .now() + .seconds(60))
        }
        defer { folder.whileReading(nil) }
        // Each read is told of by whoever ran it: the first of what it found, before the next has ended.
        #expect(await themes.read())
        var turns = 0
        while answers.all.count < 3 {
            turns += 1
            try #require(turns < 2_000, "Whoever waited to read the folder was never let.")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(answers.all == [false, false, true])
        #expect(folder.reads == 2 && themes.themes.map(\.rawValue) == ["dusk"])
        // Reading is over: the next asking reads.
        #expect(await themes.read() == false && folder.reads == 3)
    }

    @Test func aThemeFileThatChangedIsAnotherThemeUnderItsID() async throws {
        let folder = ThemeFolderInMemory([try ThemeFixture.file()])
        let themes = themes(reading: folder.reader)
        #expect(await themes.read())
        let before = try #require(ColorTheme.named("meadow", among: themes))
        let changed = try changedMeadow()
        folder.hold([changed])
        #expect(await themes.read())
        let after = try #require(ColorTheme.named("meadow", among: themes))
        #expect(before != after && before.rawValue == after.rawValue && before.hashValue == after.hashValue)
        #expect(after.seed == Self.changedSeed)
        #expect(ColorThemeOptions(palette: before) != ColorThemeOptions(palette: after))
        // The same theme written another way is the same theme.
        folder.hold([padded(changed, to: changed.data.count + 8)])
        #expect(await themes.read() == false)
        #expect(ColorTheme.named("meadow", among: themes) == after)
    }

    @Test func whenTheFolderHoldsOtherThemesTheKeptCopyFollowsAndWindowsAreTold() async throws {
        let preferences = try Prefs.isolated()
        let defaults = preferences.defaults
        let told = Tellings()
        let observer = counting(told, in: preferences)
        defer { preferences.notifications.removeObserver(observer) }
        let file = try ThemeFixture.file()
        let folder = ThemeFolderInMemory([file])
        let themes = themes(reading: folder.reader)

        await preferences.readThemes(of: themes)
        #expect(told.count == 1)
        ColorThemeOptions(palette: try #require(ColorTheme.named("meadow", among: themes))).save(in: defaults, userThemes: themes)
        await preferences.readThemes(of: themes)
        #expect(told.count == 1 && defaults.data(forKey: Self.keptFileKey) == file.data)

        let changed = try changedMeadow()
        folder.hold([changed])
        await preferences.readThemes(of: themes)
        #expect(told.count == 2 && defaults.data(forKey: Self.keptFileKey) == changed.data)
        #expect(preferences.colorThemeOptions(among: themes).palette.seed == Self.changedSeed)

        // A theme whose file is gone stays chosen, is drawn as the system's, and comes back with its file.
        folder.hold([])
        await preferences.readThemes(of: themes)
        #expect(told.count == 3 && defaults.object(forKey: Self.keptFileKey) == nil)
        #expect(defaults.string(forKey: "colorTheme") == "meadow")
        #expect(preferences.colorThemeOptions(among: themes).palette == .system)
        folder.hold([file])
        await preferences.readThemes(of: themes)
        #expect(told.count == 4 && defaults.data(forKey: Self.keptFileKey) == file.data)
        #expect(preferences.colorThemeOptions(among: themes).palette.rawValue == "meadow")
    }

    @Test func aFolderThatCouldNotBeListedSaysNothingAndTheKeptCopyStillDrawsTheTheme() async throws {
        let preferences = try Prefs.isolated()
        let defaults = preferences.defaults
        let told = Tellings()
        let observer = counting(told, in: preferences)
        defer { preferences.notifications.removeObserver(observer) }
        let file = try ThemeFixture.file()
        let folder = ThemeFolderInMemory([file])
        let running = themes(reading: folder.reader)
        await preferences.readThemes(of: running)
        preferences.choose(ColorThemeOptions(palette: try #require(ColorTheme.named("meadow", among: running))), among: running)
        #expect(told.count == 2)

        // A folder that is there and can't be listed (its disk is away, say) is no empty folder.
        folder.refuseToBeListed()
        await preferences.readThemes(of: running)
        #expect(told.count == 2 && running.themes.map(\.rawValue) == ["meadow"])
        #expect(defaults.data(forKey: Self.keptFileKey) == file.data)
        let relaunched = themes(reading: folder.reader)
        relaunched.rememberChoice(in: defaults)
        await preferences.readThemes(of: relaunched)
        #expect(preferences.colorThemeOptions(among: relaunched).palette.rawValue == "meadow")
        #expect(told.count == 2 && defaults.data(forKey: Self.keptFileKey) == file.data && folder.reads == 3)

        // Listed again, it says what it holds.
        folder.hold([])
        await preferences.readThemes(of: relaunched)
        #expect(told.count == 3 && defaults.object(forKey: Self.keptFileKey) == nil)
        #expect(preferences.colorThemeOptions(among: relaunched).palette == .system)
    }

    @Test func aThemeFileThatCouldNotBeReadStaysAsItWasLastKnown() async throws {
        let defaults = try Prefs.isolated().defaults
        let file = try ThemeFixture.file()
        let folder = ThemeFolderInMemory([file])
        let themes = themes(reading: folder.reader)
        #expect(await themes.read())
        let meadow = try #require(ColorTheme.named("meadow", among: themes))

        folder.hold([try dusk()], unread: ["meadow.json", "never.json"])
        #expect(await themes.read())
        #expect(themes.themes.map(\.rawValue) == ["meadow", "dusk"] && ColorTheme.named("meadow", among: themes) == meadow)
        themes.keepFile(of: meadow, in: defaults)
        #expect(defaults.data(forKey: Self.keptFileKey) == file.data)
        // Nothing was ever known of a file that was never read.
        #expect(ColorTheme.named("never", among: themes) == nil)
        // Read again, the file says what it holds; gone, its theme is gone.
        folder.hold([try changedMeadow(), try dusk()])
        #expect(await themes.read() && ColorTheme.named("meadow", among: themes)?.seed == Self.changedSeed)
        folder.hold([try dusk()])
        #expect(await themes.read() && themes.themes.map(\.rawValue) == ["dusk"])
    }

    @Test func settingsShowsTheThemesAndTheChoiceAsTheyAreNow() async throws {
        let preferences = try Prefs.isolated()
        let defaults = preferences.defaults
        let folder = ThemeFolderInMemory()
        let themes = themes(reading: folder.reader)
        let choices = ThemeChoices(preferences: preferences, userThemes: themes)
        #expect(choices.palettes == [.system] + ThemeCatalog.bundled && choices.chosen == ColorThemeOptions())

        // Whatever pane is in front when the folder is read, the list is the one Appearance then shows.
        folder.hold([try ThemeFixture.file()])
        await preferences.readThemes(of: themes)
        let meadow = try #require(ColorTheme.named("meadow", among: themes))
        #expect(choices.palettes == [.system] + ThemeCatalog.bundled + [meadow])
        choices.choose(meadow)
        choices.tintWindow(false)
        #expect(choices.chosen == ColorThemeOptions(palette: meadow, tintsWindow: false))
        #expect(preferences.colorThemeOptions(among: themes) == choices.chosen)

        // A changed file is redrawn; a file that is gone leaves the system's colors, and the theme still chosen.
        folder.hold([try changedMeadow()])
        await preferences.readThemes(of: themes)
        #expect(choices.chosen.palette.seed == Self.changedSeed && choices.palettes.last?.seed == Self.changedSeed)
        folder.hold([])
        await preferences.readThemes(of: themes)
        #expect(choices.palettes == [.system] + ThemeCatalog.bundled && choices.chosen.palette == .system)
        #expect(defaults.string(forKey: "colorTheme") == "meadow")
        // The system's colors take no tint: asked for one while the theme's file is gone, nothing is saved over the
        // theme chosen.
        choices.tintWindow(true)
        #expect(defaults.string(forKey: "colorTheme") == "meadow" && defaults.object(forKey: "tintWindow") as? Bool == false)
    }

    @Test func choosingTheSystemsWhileTheChosenThemesFileIsGoneIsAChoice() async throws {
        let preferences = try Prefs.isolated()
        let defaults = preferences.defaults
        let told = Tellings()
        let observer = counting(told, in: preferences)
        defer { preferences.notifications.removeObserver(observer) }
        let file = try ThemeFixture.file()
        let folder = ThemeFolderInMemory([file])
        let themes = themes(reading: folder.reader)
        let choices = ThemeChoices(preferences: preferences, userThemes: themes)
        await preferences.readThemes(of: themes)
        choices.choose(try #require(ColorTheme.named("meadow", among: themes)))
        folder.hold([])
        await preferences.readThemes(of: themes)
        #expect(choices.chosen.palette == .system && defaults.string(forKey: "colorTheme") == "meadow")
        let toldBefore = told.count

        // It reads as the system's already, and is another choice all the same: the theme does not come back.
        choices.choose(.system)
        #expect(defaults.string(forKey: "colorTheme") == "system" && told.count == toldBefore + 1)
        folder.hold([file])
        await preferences.readThemes(of: themes)
        #expect(choices.chosen.palette == .system && preferences.colorThemeOptions(among: themes).palette == .system)
        #expect(defaults.object(forKey: Self.keptFileKey) == nil)
        // Choosing what is saved already saves and tells nothing.
        let toldAfter = told.count
        choices.choose(.system)
        #expect(told.count == toldAfter)
    }

    @Test func aThemeFileAddedSinceLaunchShowsUpAsSettingsComesForward() async throws {
        let preferences = try Prefs.isolated()
        let folder = ThemeFolderInMemory()
        let themes = themes(reading: folder.reader)
        await preferences.readThemes(of: themes)
        let settings = SettingsWindowController(preferences: preferences, userThemes: themes, tags: TagStore(preferences: preferences, copies: .live))
        defer { settings.window?.close() }
        #expect(settings.themeChoices.palettes == [.system] + ThemeCatalog.bundled)

        folder.hold([try ThemeFixture.file()])
        settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        var turns = 0
        while settings.themeChoices.palettes.last?.rawValue != "meadow" {
            turns += 1
            try #require(turns < 2_000, "Settings came forward and its themes stayed as they were.")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(themes.themes.map(\.rawValue) == ["meadow"] && folder.reads == 2)
        #expect(settings.window?.isVisible == false)
    }
}

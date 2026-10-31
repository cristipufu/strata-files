import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct LanguageSettingsTests {
    @Test func declaredAndResourceLanguagesAppearOnceAndKeepTheirVariants() throws {
        let codes = ["en", "de", "pt-BR", "pt-PT", "zh-Hans", "zh-Hant"]
        let (tree, bundle) = try fixture(declared: codes, resources: codes + ["Base"])
        let before = tree.snapshot()
        let choices = LanguageSection.availableLanguages(in: bundle)
        #expect(choices.count == codes.count)
        #expect(Set(choices) == Set(codes))
        #expect(choices.first == "en")
        #expect(tree.snapshot() == before)
    }

    @Test func languageChoicesUseEitherBundleSourceWithoutInventingEnglish() throws {
        for (declared, resources, expected): ([String]?, [String], [String]) in [
            (["de", "en", "de"], [], ["en", "de"]),
            (nil, ["de", "en", "Base"], ["en", "de"]),
            (["de", "de"], ["de", "Base"], ["de"]),
            (nil, ["Base"], []),
        ] {
            let (tree, bundle) = try fixture(declared: declared, resources: resources)
            let before = tree.snapshot()
            #expect(LanguageSection.availableLanguages(in: bundle) == expected)
            #expect(tree.snapshot() == before)
        }
    }

    private func fixture(declared: [String]?, resources: [String]) throws -> (TestTree, Bundle) {
        let tree = try TestTree("Languages.bundle/Contents/Info.plist")
        try tree.add(resources.map { "Languages.bundle/Contents/Resources/\($0).lproj/" })
        var info: [String: Any] = ["CFBundleIdentifier": "StrataLanguageSettingsTests.\(UUID().uuidString)",
                                   "CFBundlePackageType": "BNDL"]
        if let declared { info["CFBundleLocalizations"] = declared }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: tree.url("Languages.bundle/Contents/Info.plist"))
        let bundle = try #require(Bundle(url: tree.url("Languages.bundle")))
        return (tree, bundle)
    }
}

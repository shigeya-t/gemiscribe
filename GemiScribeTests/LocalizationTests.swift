import XCTest
@testable import GemiScribe

final class LocalizationTests: XCTestCase {
    /// The UI language is switched at runtime from a picker, so a key missing from one
    /// table would silently render as its raw identifier for half the users.
    func testEveryKeyIsTranslatedInBothLanguages() {
        for key in LocKey.allCases {
            XCTAssertNotNil(Strings.ja[key], "Missing Japanese string for \(key.rawValue)")
            XCTAssertNotNil(Strings.en[key], "Missing English string for \(key.rawValue)")
            XCTAssertFalse(Strings.ja[key]?.isEmpty ?? true, "Empty Japanese string for \(key.rawValue)")
            XCTAssertFalse(Strings.en[key]?.isEmpty ?? true, "Empty English string for \(key.rawValue)")
        }
    }

    func testNoStrayKeysInTables() {
        XCTAssertEqual(Set(Strings.ja.keys), Set(LocKey.allCases))
        XCTAssertEqual(Set(Strings.en.keys), Set(LocKey.allCases))
    }

    func testLocalizerFollowsSelectedLanguage() {
        let localizer = Localizer(language: .en)
        XCTAssertEqual(localizer[.sourceMicrophone], "Microphone")
        localizer.language = .ja
        XCTAssertEqual(localizer[.sourceMicrophone], "マイク")
    }

    func testFormatSubstitutesArguments() {
        let localizer = Localizer(language: .en)
        XCTAssertEqual(localizer.format(.blockCountFormat, 3, "00:01:00"), "3 blocks / 00:01:00")
    }
}

final class SourceLanguageTests: XCTestCase {

    func testAutoSendsNoLanguageCodes() {
        XCTAssertTrue(SourceLanguage.auto.languageCodes.isEmpty)
    }

    func testEveryPinnedChoiceSendsAtLeastOneBCP47Code() {
        for language in SourceLanguage.allCases where language != .auto {
            XCTAssertFalse(language.languageCodes.isEmpty, "\(language) sends nothing")
            for code in language.languageCodes {
                XCTAssertTrue(code.contains("-"), "\(code) is not a BCP-47 tag")
            }
        }
    }

    /// The API takes an array so a bilingual meeting can bias towards both languages.
    func testBilingualChoiceSendsBothCodes() {
        XCTAssertEqual(SourceLanguage.japaneseAndEnglish.languageCodes, ["ja-JP", "en-US"])
    }

    /// Preferences written before the list was widened must still load.
    func testStoredRawValuesFromTheOriginalThreeChoicesStillDecode() {
        XCTAssertEqual(SourceLanguage(rawValue: "auto"), .auto)
        XCTAssertEqual(SourceLanguage(rawValue: "ja"), .japanese)
        XCTAssertEqual(SourceLanguage(rawValue: "en"), .english)
    }

    func testChoicesAreUnique() {
        let codes = SourceLanguage.allCases.map(\.languageCodes)
        XCTAssertEqual(Set(codes.map { $0.joined() }).count, codes.count)
    }

    func testNamesAreRenderedInTheInterfaceLanguage() {
        let japanese = Localizer(language: .ja)
        XCTAssertEqual(japanese.name(of: .auto), "自動判定")
        XCTAssertEqual(japanese.name(of: .japanese), "日本語")
        XCTAssertEqual(japanese.name(of: .korean), "韓国語")
        XCTAssertEqual(japanese.name(of: .japaneseAndEnglish), "日本語 + 英語")

        let english = Localizer(language: .en)
        XCTAssertEqual(english.name(of: .auto), "Auto-detect")
        XCTAssertEqual(english.name(of: .japanese), "Japanese")
        XCTAssertEqual(english.name(of: .korean), "Korean")
        XCTAssertEqual(english.name(of: .japaneseAndEnglish), "Japanese + English")
    }

    func testEveryChoiceHasANonEmptyNameInBothInterfaceLanguages() {
        for uiLanguage in AppLanguage.allCases {
            let localizer = Localizer(language: uiLanguage)
            for language in SourceLanguage.allCases {
                let name = localizer.name(of: language)
                XCTAssertFalse(name.isEmpty)
                // Foundation returning nil would leave the BCP-47 tag showing in the menu.
                XCTAssertNotEqual(name, language.languageCodes.joined(separator: " + "),
                                  "\(language) fell back to its raw codes")
            }
        }
    }
}

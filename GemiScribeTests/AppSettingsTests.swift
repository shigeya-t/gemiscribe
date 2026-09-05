import XCTest
@testable import GemiScribe

final class AppSettingsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "GemiScribeTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSettings(uiLanguage: AppLanguage) -> AppSettings {
        defaults.set(uiLanguage.rawValue, forKey: "uiLanguage")
        return AppSettings(defaults: defaults)
    }

    func testJapaneseInterfaceDefaultsToTranslatingIntoJapanese() {
        XCTAssertEqual(makeSettings(uiLanguage: .ja).translationTarget, .ja)
    }

    func testEnglishInterfaceDefaultsToTranslatingIntoEnglish() {
        XCTAssertEqual(makeSettings(uiLanguage: .en).translationTarget, .en)
    }

    func testDefaultTargetFollowsALaterInterfaceLanguageChange() {
        let settings = makeSettings(uiLanguage: .en)
        XCTAssertEqual(settings.translationTarget, .en)

        settings.uiLanguage = .ja
        XCTAssertEqual(settings.translationTarget, .ja)
    }

    func testAnExplicitTargetSurvivesAnInterfaceLanguageChange() {
        let settings = makeSettings(uiLanguage: .ja)
        settings.translationTarget = .en   // the user picks one themselves

        settings.uiLanguage = .en
        settings.uiLanguage = .ja
        XCTAssertEqual(settings.translationTarget, .en)
    }

    func testAnExplicitTargetSurvivesRelaunch() {
        let first = makeSettings(uiLanguage: .ja)
        first.translationTarget = .en

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.translationTarget, .en)
        XCTAssertTrue(second.hasChosenTranslationTarget)

        second.uiLanguage = .ja
        XCTAssertEqual(second.translationTarget, .en)
    }

    func testChoosingTheTargetThatMatchesTheInterfaceStillCountsAsAChoice() {
        let settings = makeSettings(uiLanguage: .ja)
        settings.translationTarget = .ja   // same value, but chosen deliberately
        XCTAssertTrue(settings.hasChosenTranslationTarget)

        settings.uiLanguage = .en
        XCTAssertEqual(settings.translationTarget, .ja)
    }

    func testAudioSourceDefaultsAreSystemAudioOnly() {
        let settings = makeSettings(uiLanguage: .ja)
        XCTAssertTrue(settings.captureSystemAudio)
        XCTAssertFalse(settings.captureMicrophone)
        XCTAssertFalse(settings.smartTranscribe)
        XCTAssertTrue(settings.translationEnabled)
        XCTAssertEqual(settings.sourceLanguage, .auto)
    }
}

final class DebugLoggingFlagTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "GemiScribeTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDebugFlagEnablesLoggingForTheRun() {
        let settings = AppSettings(defaults: defaults,
                                   launchArguments: ["GemiScribe", "--debug"])
        XCTAssertTrue(settings.isDebugLoggingForced)
        XCTAssertTrue(settings.isDebugLoggingEnabled)
    }

    /// The flag must not flip the stored preference, or every later launch would log.
    func testDebugFlagDoesNotPersistThePreference() {
        _ = AppSettings(defaults: defaults, launchArguments: ["GemiScribe", "--debug"])
        XCTAssertNil(defaults.object(forKey: "debugLogging"))

        let next = AppSettings(defaults: defaults, launchArguments: ["GemiScribe"])
        XCTAssertFalse(next.isDebugLoggingForced)
        XCTAssertFalse(next.isDebugLoggingEnabled)
    }

    func testStoredPreferenceStillEnablesLoggingWithoutTheFlag() {
        defaults.set(true, forKey: "debugLogging")
        let settings = AppSettings(defaults: defaults, launchArguments: ["GemiScribe"])
        XCTAssertFalse(settings.isDebugLoggingForced)
        XCTAssertTrue(settings.isDebugLoggingEnabled)
    }
}

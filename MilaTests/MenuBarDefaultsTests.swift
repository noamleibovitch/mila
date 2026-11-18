import XCTest
@testable import Mila

final class MenuBarDefaultsTests: XCTestCase {
    func test_source_settings_default_both_on_and_honour_persisted_values() {
        let suite = "MenuBarDefaultsTests.sources.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MenuBarSourceSettings.read(from: defaults).microphone, true)
        XCTAssertEqual(MenuBarSourceSettings.read(from: defaults).appAudio, true)

        defaults.set(false, forKey: MenuBarSourceSettings.microphoneKey)
        XCTAssertEqual(MenuBarSourceSettings.read(from: defaults).microphone, false)
        XCTAssertEqual(MenuBarSourceSettings.read(from: defaults).appAudio, true)

        defaults.set(false, forKey: MenuBarSourceSettings.appAudioKey)
        let off = MenuBarSourceSettings.read(from: defaults)
        XCTAssertFalse(off.microphone)
        XCTAssertFalse(off.appAudio)
    }

    func test_ui_test_suite_is_uuid_validated_and_isolated() {
        let id = UUID()
        let resolved = MenuBarDefaults.resolve(arguments: [
            "--uitests",
            "--ui-test-menu-bar-suite=\(id.uuidString)"
        ])
        let suiteName = MenuBarDefaults.uiTestSuiteName(for: id)
        defer { resolved.removePersistentDomain(forName: suiteName) }
        let probeKey = "MenuBarDefaultsTests.probe.\(id.uuidString)"
        resolved.set("probe", forKey: probeKey)
        XCTAssertEqual(resolved.string(forKey: probeKey), "probe")
        XCTAssertNil(UserDefaults.standard.string(forKey: probeKey),
                     "The test suite must not write the user's real defaults")

        // A malformed flag must not use production defaults as a test suite.
        XCTAssertTrue(MenuBarDefaults.resolve(arguments: [
            "--ui-test-menu-bar-suite=not-a-uuid"
        ]) === UserDefaults.standard)
        XCTAssertTrue(MenuBarDefaults.resolve(arguments: ["--uitests"]) === UserDefaults.standard)
    }

    func test_first_close_notice_is_once_per_injected_suite_and_isolated() {
        let suiteA = "MenuBarDefaultsTests.noticeA.\(UUID().uuidString)"
        let suiteB = "MenuBarDefaultsTests.noticeB.\(UUID().uuidString)"
        let a = UserDefaults(suiteName: suiteA)!
        let b = UserDefaults(suiteName: suiteB)!
        defer {
            a.removePersistentDomain(forName: suiteA)
            b.removePersistentDomain(forName: suiteB)
        }

        let storeA = MenuBarFirstCloseStore(defaults: a)
        XCTAssertFalse(storeA.hasExplained)
        storeA.markExplained()
        XCTAssertTrue(storeA.hasExplained)

        // Fresh suite stays unacknowledged: the flag never leaks elsewhere.
        XCTAssertFalse(MenuBarFirstCloseStore(defaults: b).hasExplained)
    }

    func test_first_close_key_is_the_documented_stable_key() {
        XCTAssertEqual(MenuBarFirstCloseStore.explainedKey,
                       "menuBar.didExplainBackgroundRunning")
    }
}

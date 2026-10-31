import AppKit
import XCTest
@testable import OpenUsage

@MainActor
final class UpdaterPresentationControllerTests: XCTestCase {
    func testBringToFrontUsesReliableActivationAfterChangingPolicy() {
        var policy = NSApplication.ActivationPolicy.accessory
        var active = false
        var events: [String] = []
        let presentationController = UpdaterPresentationController(
            activationPolicy: { policy },
            isActive: { active },
            setActivationPolicy: { newPolicy in
                events.append("policy:\(newPolicy.rawValue)")
                policy = newPolicy
                return true
            },
            activate: { ignoringOtherApps in
                events.append("activate:\(ignoringOtherApps)")
                active = true
            }
        )

        presentationController.bringToFront(reason: "test")

        XCTAssertEqual(policy, .regular)
        XCTAssertTrue(active)
        XCTAssertEqual(events, ["policy:\(NSApplication.ActivationPolicy.regular.rawValue)", "activate:true"])
    }

    func testReturnToMenuBarRestoresAccessoryPolicy() {
        var policy = NSApplication.ActivationPolicy.regular
        let presentationController = UpdaterPresentationController(
            activationPolicy: { policy },
            isActive: { true },
            setActivationPolicy: { newPolicy in
                policy = newPolicy
                return true
            },
            activate: { _ in XCTFail("Finishing must not reactivate the app") }
        )

        presentationController.returnToMenuBar()

        XCTAssertEqual(policy, .accessory)
    }
}

@MainActor
final class UpdaterUserDriverDelegateTests: XCTestCase {
    func testFinishingUpdateSessionRestoresPresentationAndClearsIndicator() {
        let delegate = UpdaterUserDriverDelegate()
        var sessionFinished = false
        var resolved = false
        delegate.onUpdateSessionFinished = { sessionFinished = true }
        delegate.onUpdateResolved = { resolved = true }

        delegate.standardUserDriverWillFinishUpdateSession()

        XCTAssertTrue(sessionFinished)
        XCTAssertTrue(resolved)
    }
}

@MainActor
final class UpdaterPreferencesTests: XCTestCase {
    private func makeController() -> UpdaterController {
        UpdaterController(presentationController: UpdaterPresentationController(
            activationPolicy: { .accessory },
            isActive: { false },
            setActivationPolicy: { _ in true },
            activate: { _ in }
        ))
    }

    func testBetaChannelDefaultsToStableWithoutWritingAnything() {
        let preferences = TestPreferences.make("updater-default")
        configureStandardPreferences(preferences)

        let controller = makeController()

        XCTAssertFalse(controller.betaChannelEnabled)
        XCTAssertNil(preferences.object(forKey: UpdaterController.betaChannelDefaultsKey))
    }

    func testBetaChannelReadsTheSeededPreference() {
        let preferences = TestPreferences.make("updater-seeded")
        preferences.set(true, forKey: UpdaterController.betaChannelDefaultsKey)
        configureStandardPreferences(preferences)

        XCTAssertTrue(makeController().betaChannelEnabled)
    }

    func testChangingTheBetaChannelPersistsAndNewControllersReadIt() {
        let preferences = TestPreferences.make("updater-persist")
        preferences.set(true, forKey: UpdaterController.betaChannelDefaultsKey)
        configureStandardPreferences(preferences)
        let controller = makeController()

        controller.betaChannelEnabled = false

        XCTAssertEqual(preferences.object(forKey: UpdaterController.betaChannelDefaultsKey) as? Bool, false)
        XCTAssertFalse(makeController().betaChannelEnabled)

        controller.betaChannelEnabled = true

        XCTAssertEqual(preferences.object(forKey: UpdaterController.betaChannelDefaultsKey) as? Bool, true)
        XCTAssertTrue(makeController().betaChannelEnabled)
    }

    func testResetToDefaultsPersistsTheStableChannel() {
        let preferences = TestPreferences.make("updater-reset")
        preferences.set(true, forKey: UpdaterController.betaChannelDefaultsKey)
        configureStandardPreferences(preferences)
        let controller = makeController()

        controller.resetToDefaults()

        XCTAssertEqual(preferences.object(forKey: UpdaterController.betaChannelDefaultsKey) as? Bool, false)
        XCTAssertFalse(makeController().betaChannelEnabled)
    }
}

import Foundation
import Observation

/// One-time onboarding state. Today that's a single bit: whether the dashboard should still show the
/// first-run Customize hint card. `FirstRunSeeder` marks it pending when it seeds a fresh install's
/// provider set (existing installs are never seeded, so they never see the card); it clears when the
/// user dismisses the card, visits Customize, or leaves the welcome screen with nothing on.
@MainActor
@Observable
final class OnboardingStore {
    private static let customizeHintPendingKey = "openusage.onboarding.customizeHintPending"

    private(set) var isCustomizeHintPending: Bool
    private let preferences: AppPreferences

    init(defaults preferences: AppPreferences = .standard) {
        self.preferences = preferences
        self.isCustomizeHintPending = preferences.bool(forKey: Self.customizeHintPendingKey)
    }

    func markCustomizeHintPending() {
        guard !isCustomizeHintPending else { return }
        isCustomizeHintPending = true
        preferences.set(true, forKey: Self.customizeHintPendingKey)
    }

    func dismissCustomizeHint() {
        guard isCustomizeHintPending else { return }
        isCustomizeHintPending = false
        preferences.set(false, forKey: Self.customizeHintPendingKey)
    }
}

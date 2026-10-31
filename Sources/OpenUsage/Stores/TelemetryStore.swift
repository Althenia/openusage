import Foundation

/// Per-provider running tally for one local calendar day. Persisted so counts survive app restarts
/// within a day, then emitted as a single `provider_refresh_daily` event once the day rolls over.
struct ProviderDailyCounter: Codable, Sendable, Equatable {
    var day: String
    var success = 0
    var failure = 0
    var manual = 0
    /// Stable `ErrorCategory` raw value -> count. No messages, no PII.
    var errors: [String: Int] = [:]
}

/// Telemetry bookkeeping kept in its own preferences namespace (`AppPreferences.telemetry`), separate
/// from the app's settings namespace. That isolation keeps the anonymous install id, the user's
/// optional-analytics choice, and the daily-dedup state independent of app settings — so a settings
/// change can never re-enable extra analytics the user turned off or mint a new install id (which
/// would inflate DAU / new-install counts). Daily activity and crash reports ignore that choice.
@MainActor
final class TelemetryStore {
    private let preferences: AppPreferences

    private static let installIDKey = "installID"
    private static let enabledKey = "enabled"
    private static let activeDayKey = "activeDay"
    private static let providerDaysKey = "providerDays"

    init(defaults preferences: AppPreferences = .telemetry) {
        self.preferences = preferences
    }

    /// Stable anonymous install id (random UUID), minted once on first read and reused thereafter.
    var installID: String {
        if let existing = preferences.string(forKey: Self.installIDKey) { return existing }
        let minted = UUID().uuidString
        preferences.set(minted, forKey: Self.installIDKey)
        return minted
    }

    /// Whether optional usage analytics are enabled (provider rollups and error categories).
    /// Defaults to `true` when the user has never chosen. Existing opt-outs stay stored here; the
    /// daily active ping and crash reports do not read this flag.
    var enabled: Bool {
        get { preferences.bool(forKey: Self.enabledKey, default: true) }
        set { preferences.set(newValue, forKey: Self.enabledKey) }
    }

    /// The last local day on which `app_daily_active` was emitted (`yyyy-MM-dd`), or nil if never.
    var activeDay: String? {
        get { preferences.string(forKey: Self.activeDayKey) }
        set { preferences.set(newValue, forKey: Self.activeDayKey) }
    }

    func providerCounters() -> [String: ProviderDailyCounter] {
        guard let data = preferences.data(forKey: Self.providerDaysKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ProviderDailyCounter].self, from: data)) ?? [:]
    }

    func setProviderCounters(_ counters: [String: ProviderDailyCounter]) {
        guard let data = try? JSONEncoder().encode(counters) else {
            AppLog.warn(.config, "failed to persist telemetry counters")
            return
        }
        preferences.set(data, forKey: Self.providerDaysKey)
    }
}

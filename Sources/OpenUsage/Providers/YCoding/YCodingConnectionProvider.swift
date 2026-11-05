import CryptoKit
import Foundation

/// A connection is a YCoding profile, not an inferred person, account, or API-key kind.
extension YCodingConnection {
    var family: String {
        switch integrationID {
        case "openai": "codex"
        case "anthropic": "claude"
        default: integrationID
        }
    }

    var cardID: String {
        // Length-delimited, case-sensitive identity; labels and active state can change independently.
        let identity = "\(integrationID.utf8.count):\(integrationID)\(id.utf8.count):\(id)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(family)@ycoding-\(digest)"
    }

    var provider: Provider {
        let names = ["openai": "OpenAI", "anthropic": "Anthropic", "antigravity": "Antigravity",
                     "muse": "Muse", "cursor": "Cursor"]
        return Provider(id: cardID, displayName: "\(names[integrationID] ?? integrationID): \(profile)",
                        icon: .providerMark(family))
    }
}

struct YCodingConnectionRead: Sendable {
    let connections: [YCodingConnection]
    let quotas: [YCodingQuotaSnapshot]
    let today: [YCodingProfileUsage]
    let yesterday: [YCodingProfileUsage]
    let last30: [YCodingProfileUsage]
    let warning: String?
}

/// All profile cards share one bounded read so automatic refreshes do not multiply provider probes.
@MainActor
final class YCodingConnectionBridge {
    static let replacedLegacyFamilies: Set<String> = ["claude", "codex", "cursor"]
    private let client: any YCodingConnectionReading
    private let now: @Sendable () -> Date
    private var cached: (date: Date, manual: Bool, read: YCodingConnectionRead)?
    private var pending: (id: UUID, manual: Bool, task: Task<YCodingConnectionRead, Error>)?

    init(client: any YCodingConnectionReading = YCodingConnectionClient(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    func discover() async throws -> [YCodingConnection] { try await client.connections() }

    func read(manual: Bool) async throws -> YCodingConnectionRead {
        if let cached, now().timeIntervalSince(cached.date) < 15, !manual || cached.manual {
            return cached.read
        }
        if let pending {
            let result = try await pending.task.value
            if self.pending?.id == pending.id {
                cached = (now(), pending.manual, result)
                self.pending = nil
            }
            // A user refresh must still run YCoding's explicit probe after an automatic read.
            if manual && !pending.manual { return try await read(manual: true) }
            return result
        }
        let client = client, instant = now()
        let task = Task<YCodingConnectionRead, Error> {
            let before = try await client.connections()
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: instant)
            let previous = calendar.date(byAdding: .day, value: -1, to: start)!
            let month = calendar.date(byAdding: .day, value: -29, to: start)!
            // Reports are independent from live quota availability: ordinary inference keys often
            // have recorded usage without permission to query organization billing or subscriptions.
            async let today = Self.usage(client, from: start, to: instant.addingTimeInterval(0.001))
            async let yesterday = Self.usage(client, from: previous, to: start)
            async let last30 = Self.usage(client, from: month, to: instant.addingTimeInterval(0.001))
            let quotas: [YCodingQuotaSnapshot]
            var warning: String?
            do { quotas = try await client.snapshots(refresh: manual) }
            catch {
                quotas = []
                warning = "YCoding quotas could not be refreshed. Recorded profile usage is shown."
                AppLog.error("plugin:ycoding", warning!)
            }
            let reports = await (today, yesterday, last30)
            if reports.0 == nil || reports.1 == nil || reports.2 == nil {
                let notice = "Some YCoding recorded usage could not be read. Available quotas are shown."
                warning = [warning, notice].compactMap { $0 }.joined(separator: " ")
                AppLog.error("plugin:ycoding", notice)
            }
            let after = try await client.connections()
            // Changes in the active flag do not change identity, but additions/removals/renames do.
            let identity: (YCodingConnection) -> String = { "\($0.cardID)|\($0.profile)|\($0.authentication.rawValue)" }
            guard Set(before.map(identity)) == Set(after.map(identity)) else {
                throw YCodingProfileError.connectionsChanged
            }
            return YCodingConnectionRead(connections: after, quotas: quotas,
                                         today: reports.0 ?? [], yesterday: reports.1 ?? [], last30: reports.2 ?? [],
                                         warning: warning)
        }
        let id = UUID()
        pending = (id, manual, task)
        defer { if pending?.id == id { pending = nil } }
        let result = try await task.value
        cached = (now(), manual, result)
        return result
    }

    private static func usage(_ client: any YCodingConnectionReading, from: Date, to: Date) async -> [YCodingProfileUsage]? {
        do { return try await client.usage(from: from, to: to) }
        catch { return nil } // The caller logs and surfaces a fixed, non-secret partial-data notice.
    }
}

@MainActor
final class YCodingConnectionProvider: ProviderRuntime {
    let connection: YCodingConnection
    let bridge: YCodingConnectionBridge
    var provider: Provider { connection.provider }
    var widgetDescriptors: [WidgetDescriptor] { YCodingConnectionMapper.descriptors(for: connection) }

    init(connection: YCodingConnection, bridge: YCodingConnectionBridge) {
        self.connection = connection
        self.bridge = bridge
    }

    // Discovery has already verified local connection metadata; do not repeat network probes here.
    func hasLocalCredentials() async -> Bool { true }

    func refresh() async -> ProviderSnapshot {
        do {
            let read = try await bridge.read(manual: ProviderRefreshContext.isManual)
            guard read.connections.contains(where: {
                $0.integrationID == connection.integrationID && $0.id == connection.id && $0.profile == connection.profile &&
                    $0.authentication == connection.authentication
            }) else { throw YCodingProfileError.connectionsChanged }
            return YCodingConnectionMapper.snapshot(for: connection, read: read)
        } catch {
            // Never propagate process output, response bodies, or arbitrary upstream error text.
            let safe = error as? YCodingProfileError
            let clientError = error as? YCodingConnectionClientError
            let message = safe?.localizedDescription ?? clientError?.localizedDescription
                ?? "YCoding profile usage could not be read. Open YCoding and try again."
            AppLog.error("plugin:ycoding", message)
            return .error(provider: provider, message: message, category: .notAvailable)
        }
    }
}

enum YCodingProfileError: Error, LocalizedError {
    case connectionsChanged
    var errorDescription: String? {
        "The YCoding connections changed. Restart OpenUsage to load the current profiles."
    }
}

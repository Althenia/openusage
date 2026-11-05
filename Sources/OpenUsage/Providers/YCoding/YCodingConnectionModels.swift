import Foundation

/// Only the connection's explicit non-secret kind classifies its authentication. The integration's
/// available login methods, profile names, and quota status never identify an existing connection.
struct YCodingConnection: Equatable, Sendable {
    enum Authentication: String, Sendable { case account = "oauth", apiKey = "key", unknown }

    let integrationID: String
    let id: String
    let profile: String
    let active: Bool
    let authentication: Authentication

    init(integrationID: String, id: String, profile: String, active: Bool,
         authentication: Authentication = .unknown) {
        self.integrationID = integrationID
        self.id = id
        self.profile = profile
        self.active = active
        self.authentication = authentication
    }

    var distinguishesAccountAndKey: Bool { integrationID == "openai" || integrationID == "anthropic" }
    var showsSubscriptionQuotas: Bool { !distinguishesAccountAndKey || authentication != .apiKey }
    var sourceLabel: String {
        guard distinguishesAccountAndKey else { return "YCoding" }
        return switch authentication {
        case .account: "YCoding · Account"
        case .apiKey: "YCoding · API Key"
        case .unknown: "YCoding · Type Unknown"
        }
    }

    static let supportedIntegrations: Set<String> = ["openai", "anthropic", "antigravity", "muse", "cursor"]
}

struct YCodingQuotaSnapshot: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case available, stale, unsupported, unauthorized, error
    }
    enum Source: String, Decodable, Sendable {
        case providerAPI = "provider_api"
        case localClientRPC = "local_client_rpc"
        case responseHeaders = "response_headers"
        case responseStream = "response_stream"
        case providerInternalAPI = "provider_internal_api"
        case localSession = "local_session"
    }
    enum Stability: String, Decodable, Sendable {
        case stable, clientContract = "client_contract", observed, bestEffort = "best_effort"
    }

    let providerID: String
    let label: String
    let profile: String?
    let status: Status
    let source: Source
    let stability: Stability
    /// YCoding timestamps are UTC epoch milliseconds, including resetAt below.
    let updatedAt: Double
    let windows: [YCodingQuotaWindow]
    let message: String?

    /// YCoding's quota API identifies profiles by exact label, not credential ID. The caller must
    /// verify connection metadata again after the request before accepting a refresh. A single
    /// connection's profile is omitted by that API. Only an unambiguous adapter snapshot may fill
    /// that gap; unbound observations and local/app-server aggregates are never another account.
    static func matching(
        _ connection: YCodingConnection,
        connections: [YCodingConnection],
        snapshots: [Self]
    ) -> Self? {
        let siblings = connections.filter { $0.integrationID == connection.integrationID }
        guard siblings.contains(where: {
            $0.id == connection.id && $0.profile == connection.profile && $0.authentication == connection.authentication
        }),
              Set(siblings.map(\.profile)).count == siblings.count else { return nil }
        let eligible = snapshots.filter {
            $0.providerID == connection.integrationID && $0.source != .localSession && $0.source != .localClientRPC
        }
        let named = eligible.filter { $0.profile == connection.profile }
        if named.count == 1 { return named[0] }
        guard named.isEmpty, siblings.count == 1 else { return nil }
        let unnamed = eligible.filter {
            // YCoding binds every Muse observation to the credential/account-generation digest,
            // including the sole-profile case. Its list appends unbound observations only when
            // there are several stored profiles. Other response sources offer no such guarantee.
            let boundMuse = connection.integrationID == "muse" && $0.source == .responseStream
            return $0.profile == nil && ($0.source == .providerAPI || $0.source == .providerInternalAPI || boundMuse)
        }
        return unnamed.count == 1 ? unnamed[0] : nil
    }
}

struct YCodingQuotaWindow: Decodable, Equatable, Sendable {
    enum Unit: String, Decodable, Sendable { case percent, usd, requests, tokens, count }
    let id: String
    let label: String
    let group: String?
    let unit: Unit
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let unlimited: Bool?
    let resetAt: Double?
    let periodSeconds: Double?
}

struct YCodingTokenUsage: Decodable, Equatable, Sendable {
    struct Cache: Decodable, Equatable, Sendable {
        let read: Double
        let write: Double
    }
    let input: Double
    let output: Double
    let reasoning: Double
    let cache: Cache
}

struct YCodingCostCoverage: Decodable, Equatable, Sendable {
    let pricedRequests: Int
    let unpricedRequests: Int
}

/// Only request-time recorded profiles are returned. Historical "provider-default" rows cannot
/// be assigned to today's active connection, even when only one connection currently exists.
struct YCodingProfileUsage: Equatable, Sendable {
    let providerID: String
    let profile: String
    let cost: Double?
    let costProvenance: String?
    let costCoverage: YCodingCostCoverage?
    let tokens: YCodingTokenUsage
    let physical: Int
    var estimatedRequests: Int = 0
    var usesOpenUsagePricing: Bool = false
    var models: [ModelUsageEntry] = []

    init(
        providerID: String,
        profile: String,
        cost: Double?,
        costProvenance: String?,
        costCoverage: YCodingCostCoverage?,
        tokens: YCodingTokenUsage,
        physical: Int,
        estimatedRequests: Int = 0,
        usesOpenUsagePricing: Bool = false,
        models: [ModelUsageEntry] = []
    ) {
        self.providerID = providerID
        self.profile = profile
        self.cost = cost
        self.costProvenance = costProvenance
        self.costCoverage = costCoverage
        self.tokens = tokens
        self.physical = physical
        self.estimatedRequests = estimatedRequests
        self.usesOpenUsagePricing = usesOpenUsagePricing
        self.models = models
    }

    var hasIncompleteCost: Bool {
        cost == nil || costCoverage == nil || (costCoverage?.unpricedRequests ?? 0) > estimatedRequests
    }
}

import Foundation

struct ClaudeProfileLogin: Equatable, Sendable {
    let profile: ProviderProfile
    let identityKey: String
    let label: String?
}

extension ProviderAccountAssembly {
    static func observeClaudeProfiles(
        _ profiles: [ProviderProfile], observer: DefaultAccountObserver
    ) -> [ClaudeProfileLogin] {
        profiles.filter { $0.family == .claude }.compactMap { profile in
            switch observer.observeClaude(configDirectory: profile.directory) {
            case .resolved(let identityKey, let label, _):
                return ClaudeProfileLogin(profile: profile, identityKey: identityKey, label: label)
            case .unresolved(let reason):
                AppLog.warn(.config, "accounts: Claude profile \(profile.name) has no usable login — \(reason)")
            case .absent:
                AppLog.warn(.config, "accounts: Claude profile \(profile.name) has no login")
            }
            return nil
        }
    }

    static func applyClaudeProfiles(
        _ logins: [ClaudeProfileLogin],
        to cards: inout [ClaudeAccountCard],
        records: [ProviderAccountRecord],
        allowsUnattributedPiUsage: Bool,
        identityKeys: inout [String: String]
    ) {
        for login in logins {
            let directory = login.profile.directory
            let displayName = "Claude: \(login.profile.name)"
            if let index = cards.firstIndex(where: { $0.identityKey == login.identityKey }) {
                if cards[index].profileName == nil {
                    cards[index].profileName = login.profile.name
                    cards[index].displayName = displayName
                }
                if !cards[index].ownedLogDirectories.contains(directory) {
                    cards[index].ownedLogDirectories.append(directory)
                }
                if cards[index].configDirectory != directory,
                   !cards[index].mergedProfileDirectories.contains(directory) {
                    cards[index].mergedProfileDirectories.append(directory)
                }
                continue
            }
            guard let record = records.first(where: {
                $0.family == "claude" && $0.identityKey == login.identityKey && !$0.removedTombstone
            }) else { continue }
            let parts = login.identityKey.split(separator: "|")
            cards.append(ClaudeAccountCard(
                id: record.id, identityKey: login.identityKey,
                organizationID: parts.count == 2 ? String(parts[1]) : nil,
                displayName: displayName, usesDesktopCredentials: false,
                allowsUnattributedPiUsage: allowsUnattributedPiUsage,
                profileName: login.profile.name, configDirectory: directory, ownedLogDirectories: [directory]
            ))
            identityKeys[record.id] = login.identityKey
        }
    }

    static func codexProfileLabels(
        _ profiles: [ProviderProfile], logins: [CodexHomeLogin], homeDirectory: URL
    ) -> [String: String] {
        var labels: [String: String] = [:]
        for profile in profiles where profile.family == .codex {
            let home = CodexHomeScanner.standardizedHome(profile.directory, homeDirectory: homeDirectory)
            guard let login = logins.first(where: { $0.home == home }) else {
                AppLog.warn(.config, "accounts: Codex profile \(profile.name) has no signed-in auth.json")
                continue
            }
            if labels[login.identity.key] == nil { labels[login.identity.key] = "Codex: \(profile.name)" }
        }
        return labels
    }
}

import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    /// Families represented by direct YCoding profile cards leave YCoding credentials and history
    /// to those cards; their native runtimes keep their own logins and usage sources.
    static func make(
        defaults preferences: AppPreferences = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        codex: CodexAccountDiscovery = CodexAccountDiscovery(),
        claudeIdentityKeys: [String: String] = [:],
        excludingYCodingFamilies: Set<String> = [],
        ycodingProviders: [ProviderRuntime] = []
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name.
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider(includesYCodingUsage: !excludingYCodingFamilies.contains("claude"))]
        } else {
            providers = claudeCards.map { card in
                let identity = claudeIdentityKeys[card.id] ?? card.identityKey
                let user = identity.split(separator: "|").first.map(String.init)
                let scanner = ClaudeLogUsageScanner(
                    accountUUID: user, organizationUUID: card.organizationID,
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage,
                    additionalConfigDirectories: card.additionalLogDirectories,
                    ownedConfigDirectories: card.ownedLogDirectories
                )
                return ClaudeProvider(
                    provider: ClaudeProvider.makeProvider(
                        id: card.id,
                        displayName: claudeCards.count == 1 && card.profileName == nil ? "Claude" : card.displayName
                    ),
                    authStore: ClaudeAuthStore(
                        desktopOrganization: card.organizationID,
                        expectedIdentityKey: identity,
                        desktopOnly: card.usesDesktopCredentials,
                        swapAccount: card.swapAccount,
                        preferOrganizationScopedDesktop: claudeCards.count > 1
                            && card.organizationID != nil && !card.usesDesktopCredentials
                            && card.configDirectory == nil,
                        configDirectory: card.configDirectory,
                        profileConfigDirectories: card.mergedProfileDirectories
                    ),
                    logUsageScanner: scanner,
                    includesYCodingUsage: !excludingYCodingFamilies.contains("claude"),
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }
        if codex.cards.isEmpty {
            providers.append(CodexProvider(
                authStore: CodexAuthStore(
                    additionalAuthHomes: codex.plainAuthHomes,
                    writableAuthHomes: Set(codex.plainWritableAuthHomes),
                    piCredentialSources: codex.plainPiCredentialSources,
                    ycodingCredentialSources: excludingYCodingFamilies.contains("codex") ? [] : codex.plainYCodingCredentialSources
                ),
                logUsageScanner: CodexLogUsageScanner(additionalHomes: codex.plainAuthHomes),
                includesYCodingUsage: !excludingYCodingFamilies.contains("codex")
            ))
        } else {
            providers += codex.cards.map { card in
                CodexProvider(
                    provider: CodexProvider.makeProvider(id: card.id, displayName: card.displayName),
                    authStore: CodexAuthStore(
                        expectedIdentity: card.identity,
                        additionalAuthHomes: card.authHomes,
                        writableAuthHomes: Set(card.writableAuthHomes),
                        piCredentialSources: card.piCredentialSources,
                        ycodingCredentialSources: excludingYCodingFamilies.contains("codex") ? [] : card.ycodingCredentialSources
                    ),
                    includesYCodingUsage: !excludingYCodingFamilies.contains("codex"),
                    historyScope: .account(card.identity, codex.historyHomes, claimsPiUsage: card.claimsPiUsage)
                )
            }
        }
        providers += [
            CursorProvider(authStore: CursorAuthStore(
                includesYCodingCredentials: !excludingYCodingFamilies.contains("cursor")
            )),
            AnthropicAPIProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: preferences),
            DevinProvider(),
            GrokProvider(),
            MuseProvider(),
            OllamaProvider(),
            OpenAIAPIProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        // Keep each connection next to its existing provider family. Profiles remain separate even
        // when they belong to the same person or workspace.
        var remaining = ycodingProviders
        var ordered: [ProviderRuntime] = []
        for (index, runtime) in providers.enumerated() {
            ordered.append(runtime)
            let family = ProviderAccountID.family(of: runtime.provider.id)
            let nextFamily = providers.indices.contains(index + 1)
                ? ProviderAccountID.family(of: providers[index + 1].provider.id) : nil
            if nextFamily != family {
                ordered += remaining.filter { ProviderAccountID.family(of: $0.provider.id) == family }
                remaining.removeAll { ProviderAccountID.family(of: $0.provider.id) == family }
            }
        }
        return ordered + remaining
    }
}

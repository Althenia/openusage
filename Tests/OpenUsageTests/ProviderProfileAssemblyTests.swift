import XCTest
@testable import OpenUsage

@MainActor
final class ProviderProfileAssemblyTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures
    private let home = URL(fileURLWithPath: "/Users/dev")
    private let userA = "11111111-1111-1111-1111-111111111111"
    private let orgA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let userB = "22222222-2222-2222-2222-222222222222"
    private let orgB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let workDirectory = "/Users/dev/profiles/claude-work"
    private let aliasDirectory = "/Users/dev/profiles/claude-alias"

    private func claudeState(user: String, org: String, email: String) -> String {
        #"{"oauthAccount":{"accountUuid":"\#(user)","organizationUuid":"\#(org)","emailAddress":"\#(email)","organizationName":"Org"}}"#
    }

    private func credentials(_ access: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"refresh","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
    }

    private func profile(_ family: ProviderProfile.Family, _ name: String, _ directory: String) -> ProviderProfile {
        ProviderProfile(id: UUID(), family: family, name: name, directory: directory)
    }

    private func assemble(
        files: FakeFiles,
        profiles: [ProviderProfile],
        store: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        directories: [String: [String]] = [:]
    ) async -> ProviderAccountAssembly {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(), homeDirectory: { [home] in home }
        )
        return await ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, families: families,
            listCodexHomeDirectories: { directories[$0] ?? [] },
            desktop: ClaudeDesktopAuthStore(files: files, homeDirectory: { [home] in home }),
            listDesktopOrganizationDirectories: { _ in [] },
            profiles: profiles
        )
    }

    // MARK: - Claude

    func testClaudeProfilesGetOwnCardsAndNameTheMatchingDefaultCard() async throws {
        let files = FakeFiles([
            "/Users/dev/.claude.json": claudeState(user: userA, org: orgA, email: "a@test"),
            workDirectory + "/.claude.json": claudeState(user: userB, org: orgB, email: "b@test"),
            aliasDirectory + "/.claude.json": claudeState(user: userA, org: orgA, email: "a@test"),
        ])
        let store = ProviderAccountsStore(defaults: makeScratchDefaults("ProfileAssembly"))
        let profiles = [profile(.claude, "Work", workDirectory), profile(.claude, "Personal", aliasDirectory)]

        let assembly = await assemble(files: files, profiles: profiles, store: store, families: ["claude"])

        XCTAssertEqual(assembly.claudeCards.count, 2)
        let personal = try XCTUnwrap(assembly.claudeCards.first { $0.identityKey == "\(userA)|\(orgA)" })
        XCTAssertEqual(personal.id, "claude")
        XCTAssertEqual(personal.displayName, "Claude: Personal")
        XCTAssertEqual(personal.profileName, "Personal")
        XCTAssertNil(personal.configDirectory, "the merged card keeps its own default login")
        XCTAssertEqual(personal.ownedLogDirectories, [aliasDirectory])
        XCTAssertEqual(personal.mergedProfileDirectories, [aliasDirectory])
        let mergedAuth = try XCTUnwrap(
            ProviderCatalog.make(defaults: makeScratchDefaults("ProfileAssembly"), claudeCards: assembly.claudeCards)
                .compactMap { $0 as? ClaudeProvider }.first { $0.provider.id == "claude" }?.authStore
        )
        XCTAssertNil(mergedAuth.configDirectory)
        XCTAssertEqual(mergedAuth.profileConfigDirectories, [aliasDirectory])

        let work = try XCTUnwrap(assembly.claudeCards.first { $0.identityKey == "\(userB)|\(orgB)" })
        XCTAssertEqual(work.id, ProviderAccountID.make(family: "claude", identityKey: "\(userB)|\(orgB)"))
        XCTAssertEqual(work.displayName, "Claude: Work")
        XCTAssertEqual(work.organizationID, orgB)
        XCTAssertEqual(work.configDirectory, workDirectory)
        XCTAssertEqual(work.ownedLogDirectories, [workDirectory])
        XCTAssertFalse(work.usesDesktopCredentials)
        XCTAssertEqual(assembly.identityKeysByCard[work.id], "\(userB)|\(orgB)")
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "\(userA)|\(orgA)")
    }

    func testRemovedClaudeProfileDisappearsAndReleasesItsLabel() async throws {
        let files = FakeFiles([
            "/Users/dev/.claude.json": claudeState(user: userA, org: orgA, email: "a@test"),
            workDirectory + "/.claude.json": claudeState(user: userB, org: orgB, email: "b@test"),
            aliasDirectory + "/.claude.json": claudeState(user: userA, org: orgA, email: "a@test"),
        ])
        let store = ProviderAccountsStore(defaults: makeScratchDefaults("ProfileAssembly"))
        let profiles = [profile(.claude, "Work", workDirectory), profile(.claude, "Personal", aliasDirectory)]
        _ = await assemble(files: files, profiles: profiles, store: store, families: ["claude"])

        let removed = await assemble(files: files, profiles: [], store: store, families: ["claude"])

        XCTAssertEqual(removed.claudeCards.map(\.id), ["claude"])
        XCTAssertNil(removed.claudeCards.first?.profileName)
        XCTAssertEqual(removed.claudeCards.first?.ownedLogDirectories, [])
    }

    func testLoneClaudeProfileKeepsItsLabelAndReadsOnlyItsOwnFolder() async throws {
        let files = FakeFiles([workDirectory + "/.claude.json": claudeState(user: userB, org: orgB, email: "b@test")])
        let defaults = makeScratchDefaults("ProfileAssembly")
        let assembly = await assemble(
            files: files, profiles: [profile(.claude, "Work", workDirectory)],
            store: ProviderAccountsStore(defaults: defaults), families: ["claude"]
        )

        let providers = ProviderCatalog.make(
            defaults: defaults, claudeCards: assembly.claudeCards, claudeIdentityKeys: assembly.identityKeysByCard
        ).compactMap { $0 as? ClaudeProvider }

        XCTAssertEqual(providers.map(\.provider.displayName), ["Claude: Work"])
        let authStore = try XCTUnwrap(providers.first?.authStore)
        XCTAssertEqual(authStore.configDirectory, workDirectory)
        XCTAssertEqual(authStore.expectedIdentityKey, "\(userB)|\(orgB)")
        XCTAssertFalse(authStore.preferOrganizationScopedDesktop)
    }

    func testClaudeProfileCredentialsNeverFallBackToTheDefaultLogin() throws {
        let files = FakeFiles([workDirectory + "/.credentials.json": credentials("profile")])
        let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": credentials("default-login")])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient", "CLAUDE_CONFIG_DIR": "/Users/dev/other"]),
            files: files, keychain: keychain, expectedIdentityKey: "\(userB)|\(orgB)", configDirectory: workDirectory
        )

        let services = store.keychainServiceCandidates()
        XCTAssertEqual(services.count, 1)
        XCTAssertNotEqual(services.first, "Claude Code-credentials")
        XCTAssertEqual(store.loadCredentialCandidates().compactMap(\.oauth.accessToken), ["profile"])

        var state = try XCTUnwrap(store.loadCredentialCandidates().first)
        let generation = store.credentialGeneration()
        state.oauth.accessToken = "rotated"
        XCTAssertTrue(try store.save(state, ifUnchanged: generation))
        XCTAssertTrue(files.files[workDirectory + "/.credentials.json"]?.contains("rotated") == true)
    }

    func testMergedProfileCredentialsFollowTheCardsOwnLoginAndStayWritable() throws {
        let secondDirectory = "/Users/dev/profiles/claude-second"
        let ownHome = ("~/.claude" as NSString).expandingTildeInPath
        let profileService = try XCTUnwrap(
            ClaudeAuthStore(environment: FakeEnvironment([:]), configDirectory: aliasDirectory).keychainServiceCandidates().first
        )
        let files = FakeFiles([
            aliasDirectory + "/.credentials.json": credentials("alias-file"),
            secondDirectory + "/.credentials.json": credentials("second-file"),
            ownHome + "/.credentials.json": credentials("own-home-duplicate"),
        ])
        let keychain = ServiceKeychain(currentUserValues: [
            "Claude Code-credentials": credentials("default"),
            profileService: credentials("alias-keychain"),
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient"]), files: files, keychain: keychain,
            expectedIdentityKey: "\(userA)|\(orgA)",
            profileConfigDirectories: [aliasDirectory, secondDirectory, ownHome, aliasDirectory]
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.compactMap(\.oauth.accessToken),
                       ["default", "alias-keychain", "alias-file", "second-file", "ambient"])
        XCTAssertEqual(candidates.last?.source, .environment)
        var state = try XCTUnwrap(candidates.first { $0.oauth.accessToken == "second-file" })
        XCTAssertEqual(state.source, .accountFile(path: secondDirectory + "/.credentials.json"))
        let generation = store.credentialGeneration()
        state.oauth.accessToken = "rotated"
        XCTAssertTrue(try store.save(state, ifUnchanged: generation))
        XCTAssertTrue(files.files[secondDirectory + "/.credentials.json"]?.contains("rotated") == true)
    }

    func testMergedProfileLoginSuppliesLimitsWhenTheDefaultLoginIsExpired() async {
        let expired = #"{"claudeAiOauth":{"accessToken":"default-expired","refreshToken":"dead","expiresAt":1,"scopes":["user:profile"]}}"#
        let files = FakeFiles([aliasDirectory + "/.credentials.json": credentials("profile-live")])
        let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": expired])
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/v1/oauth/token") {
                return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            guard request.headers["Authorization"] == "Bearer profile-live" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"five_hour":{"utilization":40,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8))
        }
        let now = Date(timeIntervalSince1970: 1_771_603_200)
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment([:]), files: files, keychain: keychain,
                profileConfigDirectories: [aliasDirectory], now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("expected live Session usage from the profile login, got \(snapshot.lines)")
        }
        XCTAssertEqual(used, 40)
        XCTAssertEqual(keychain.currentUserValues["Claude Code-credentials"], expired)
    }

    func testOwnedFolderClaimsItsUnattributedSessionsOnly() async throws {
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        func line(_ id: String, input: Int) -> String {
            ClaudeLogFixture.usageLine(timestamp: timestamp, input: input, output: 0, costUSD: 1, messageID: id, requestID: id)
        }
        let userHome = try ClaudeLogFixture.makeUserHome(claudeFiles: ["workspace/default.jsonl": line("default", input: 1000)])
        let profileHome = try ClaudeLogFixture.makeHome(files: [
            "workspace/plain.jsonl": line("plain", input: 100),
            "workspace/foreign.jsonl": #"{"ownerOrganizationUuid":"org-other","ownerAccountUuid":"user-b"}"# + "\n"
                + line("foreign", input: 5000),
        ])
        func scanner(owned: [String]) -> ClaudeLogUsageScanner {
            ClaudeLogUsageScanner(
                environment: FakeEnvironment([:]), homeDirectory: { userHome },
                incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(),
                accountUUID: "user-b", organizationUUID: "org-b",
                currentDefaultLoginIdentity: { "user-a|org-a" },
                ownedConfigDirectories: owned
            )
        }
        let pricing = ModelPricing(
            supplement: PricingSupplement(), primary: PricingCatalog(entries: [:]), secondary: PricingCatalog(entries: [:])
        )

        let owned = await scanner(owned: [profileHome.path]).scan(now: now, pricing: pricing)
        let unowned = await scanner(owned: []).scan(now: now, pricing: pricing)

        XCTAssertEqual(owned?.series.daily.first?.totalTokens, 100)
        XCTAssertNil(unowned)
    }

    // MARK: - Codex

    func testCodexProfilesGetOwnCardsAndNameTheMatchingDiscoveredCard() async throws {
        let workHome = "/Users/dev/work/codex"
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            "/Users/dev/.codex-alt/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            workHome + "/auth.json": Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test"),
        ])
        let store = ProviderAccountsStore(defaults: makeScratchDefaults("ProfileAssembly"))
        let profiles = [profile(.codex, "Work", workHome), profile(.codex, "Alias", "/Users/dev/.codex-alt")]

        let assembly = await assemble(
            files: files, profiles: profiles, store: store, families: ["codex"],
            directories: ["/Users/dev": [".codex-alt"]]
        )

        XCTAssertEqual(assembly.codexCards.count, 2)
        let alias = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "acct-a" })
        XCTAssertEqual(alias.id, "codex")
        XCTAssertEqual(alias.displayName, "Codex: Alias")
        XCTAssertEqual(alias.authHomes, ["/Users/dev/.codex", "/Users/dev/.codex-alt"])
        let work = try XCTUnwrap(assembly.codexCards.first { $0.identity.accountID == "acct-b" })
        XCTAssertEqual(work.displayName, "Codex: Work")
        XCTAssertEqual(work.authHomes, [workHome])
        XCTAssertEqual(work.writableAuthHomes, [workHome])
        XCTAssertTrue(assembly.codex.historyHomes.homes.contains(workHome))
        XCTAssertEqual(assembly.codex.historyHomes.ownedHomes(by: work.identity, files: files), [workHome])
    }

    func testLoneCodexProfileGetsANamedCardAndRemovalDropsIt() async throws {
        let workHome = "/Users/dev/work/codex"
        let files = FakeFiles([
            "/Users/dev/.codex/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
            workHome + "/auth.json": Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test"),
        ])
        let defaults = makeScratchDefaults("ProfileAssembly")
        let store = ProviderAccountsStore(defaults: defaults)

        let named = await assemble(files: files, profiles: [profile(.codex, "Main", workHome)], store: store, families: ["codex"])
        XCTAssertEqual(named.codexCards.map(\.displayName), ["Codex: Main"])
        XCTAssertEqual(named.codexCards.first?.authHomes, ["/Users/dev/.codex", workHome])
        let providers = ProviderCatalog.make(defaults: defaults, codex: named.codex).compactMap { $0 as? CodexProvider }
        XCTAssertEqual(providers.map(\.provider.displayName), ["Codex: Main"])

        let removed = await assemble(files: files, profiles: [], store: store, families: ["codex"])
        XCTAssertEqual(removed.codexCards.map(\.id), ["codex"])
        XCTAssertNotEqual(removed.codexCards.first?.displayName, "Codex: Main")
        XCTAssertEqual(removed.codexCards.first?.authHomes, ["/Users/dev/.codex"])
    }
}

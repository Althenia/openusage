import XCTest
@testable import OpenUsage

/// Direct YCoding profile cards own their usage; native cards must never import it a second time.
@MainActor
final class NativeYCodingIsolationTests: XCTestCase {
    func testCatalogExclusionIsPerFamilyAndDropsLegacyCodexCredentials() throws {
        let source = CodexYCodingCredentialSource(databasePath: "/fixture/ycoding.db")
        let codex = CodexAccountDiscovery(plainYCodingCredentialSources: [source])
        let providers = ProviderCatalog.make(
            defaults: makeScratchDefaults(), codex: codex,
            excludingYCodingFamilies: ["codex", "cursor"]
        )

        XCTAssertTrue(try XCTUnwrap(providers.compactMap { $0 as? ClaudeProvider }.first).includesYCodingUsage)
        let nativeCodex = try XCTUnwrap(providers.compactMap { $0 as? CodexProvider }.first)
        XCTAssertFalse(nativeCodex.includesYCodingUsage)
        XCTAssertTrue(nativeCodex.authStore.ycodingCredentialSources.isEmpty)
        XCTAssertFalse(try XCTUnwrap(providers.compactMap { $0 as? CursorProvider }.first)
            .authStore.includesYCodingCredentials)
    }

    func testCursorExclusionSkipsYCodingDatabaseButKeepsNativeLogin() throws {
        let sqlite = RecordingYCodingSQLite()
        let reader = YCodingCredentialReader(
            sqlite: sqlite, files: FakeFiles(["/fixture/ycoding.db": ""]),
            environment: FakeEnvironment(), databasePath: "/fixture/ycoding.db"
        )
        let store = CursorAuthStore(
            sqlite: KeyValueSQLite(), keychain: FakeKeychain(), ycodingCredentials: reader,
            includesYCodingCredentials: false
        )
        XCTAssertNil(store.loadAuthState())
        XCTAssertEqual(sqlite.queryCount, 0)

        let nativeStore = CursorAuthStore(
            sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: "native-fixture-token"]),
            keychain: FakeKeychain(), ycodingCredentials: reader, includesYCodingCredentials: false
        )
        XCTAssertEqual(nativeStore.loadAuthState()?.source, .sqlite)
        XCTAssertEqual(sqlite.queryCount, 0)
    }

    func testCodexExclusionSkipsFoldedYCodingHistory() async {
        let sqlite = RecordingYCodingSQLite()
        let provider = CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain()),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            piUsageScanner: CodexLogFixture.noPi(),
            openCodeUsageScanner: OpenCodeCodexUsageScanner(databasePaths: { [] }),
            yCodingUsageScanner: YCodingUsageScanner(sqlite: sqlite, databasePath: { "/fixture/ycoding.db" }),
            includesYCodingUsage: false, pricing: { .empty }, fallbackModel: { nil }
        )

        let snapshot = await provider.snapshot(mapped: CodexMappedUsage(plan: nil, lines: []))

        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertEqual(sqlite.queryCount, 0)
    }

    func testClaudeExclusionSkipsFoldedYCodingHistoryWithoutReadingPi() async {
        let sqlite = RecordingYCodingSQLite()
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain()
            ),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            yCodingUsageScanner: YCodingUsageScanner(sqlite: sqlite, databasePath: { "/fixture/ycoding.db" }),
            includesYCodingUsage: false, allowsUnattributedPiUsage: false, pricing: { .empty }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(sqlite.queryCount, 0)
    }
}

private final class RecordingYCodingSQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var queryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.lock()
        reads += 1
        lock.unlock()
        return nil
    }

    func execute(path: String, sql: String) throws {
        XCTFail("Isolation tests must not write YCoding state")
    }
}

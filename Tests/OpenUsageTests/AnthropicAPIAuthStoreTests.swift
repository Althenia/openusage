import XCTest
@testable import OpenUsage

final class AnthropicAPIAuthStoreTests: XCTestCase {
    func testDedicatedSourcesAndConfigPrecedence() {
        XCTAssertEqual(AnthropicAPIAuthStore.configPaths, ["~/.config/openusage/anthropic-api.json"])
        XCTAssertEqual(AnthropicAPIAuthStore.environmentNames, ["ANTHROPIC_ADMIN_API_KEY"])
        let path = AnthropicAPIAuthStore.configPaths[0]
        for text in [#"{"apiKey":"file-key"}"#, #"{"api_key":"file-key"}"#, #"{"key":"file-key"}"#, "  file-key\n"] {
            let store = AnthropicAPIAuthStore(
                files: FakeFiles([path: text]),
                environment: FakeEnvironment(["ANTHROPIC_ADMIN_API_KEY": "env-key"])
            )
            XCTAssertEqual(store.loadAPIKey(), "file-key")
            XCTAssertEqual(store.currentAPIKey(), "file-key")
            XCTAssertEqual(store.keyStatus(), .overrideActive)
        }
    }

    func testDoesNotReadOrdinaryInferenceKeysOrOtherProviderFiles() {
        let store = AnthropicAPIAuthStore(
            files: FakeFiles(["~/.config/openusage/claude.json": "other-key"]),
            environment: FakeEnvironment(["ANTHROPIC_API_KEY": "inference-key", "ANTHROPIC_AUTH_TOKEN": "oauth-token"])
        )
        XCTAssertNil(store.loadAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testKeyStatesAndBlankSources() {
        let path = AnthropicAPIAuthStore.configPaths[0]
        let cases: [([String: String], [String: String], APIKeyStatus, String?)] = [
            ([:], [:], .notSet, nil),
            ([path: "  "], ["ANTHROPIC_ADMIN_API_KEY": "  "], .notSet, nil),
            ([path: #"{"unrelated":1}"#], ["ANTHROPIC_ADMIN_API_KEY": " env-key\n"], .fromEnvironment, "env-key"),
            ([path: "file-key"], [:], .saved, "file-key")
        ]
        for (files, environment, status, key) in cases {
            let store = AnthropicAPIAuthStore(files: FakeFiles(files), environment: FakeEnvironment(environment))
            XCTAssertEqual(store.keyStatus(), status)
            XCTAssertEqual(store.loadAPIKey(), key)
        }
    }

    func testSaveAndDeleteRoundTripThroughSharedStore() throws {
        let files = FakeFiles()
        let store = AnthropicAPIAuthStore(files: files, environment: FakeEnvironment(["ANTHROPIC_ADMIN_API_KEY": "env-key"]))
        try store.saveAPIKey("  saved-key\n")
        XCTAssertEqual(files.files, [AnthropicAPIAuthStore.configPaths[0]: #"{"apiKey":"saved-key"}"#])
        XCTAssertEqual(store.loadAPIKey(), "saved-key")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
        try store.deleteAPIKey()
        XCTAssertEqual(store.loadAPIKey(), "env-key")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        try store.deleteAPIKey()
        XCTAssertTrue(files.files.isEmpty)
    }

    func testEmptySaveIsRejectedWithoutWriting() {
        let files = FakeFiles()
        let store = AnthropicAPIAuthStore(files: files, environment: FakeEnvironment())
        XCTAssertThrowsError(try store.saveAPIKey(" \n")) {
            XCTAssertEqual($0 as? AnthropicAPIError, .missingKey)
        }
        XCTAssertTrue(files.files.isEmpty)
    }

    func testPersistenceFailuresAreTyped() {
        let store = AnthropicAPIAuthStore(files: AnthropicAPIFailingFiles(), environment: FakeEnvironment())
        XCTAssertThrowsError(try store.saveAPIKey("synthetic-key")) {
            XCTAssertEqual($0 as? AnthropicAPIError, .saveFailed)
        }
        XCTAssertThrowsError(try store.deleteAPIKey()) {
            XCTAssertEqual($0 as? AnthropicAPIError, .deleteFailed)
        }
    }
}

private struct AnthropicAPIFailingFiles: TextFileAccessing {
    func exists(_ path: String) -> Bool { true }
    func readText(_ path: String) throws -> String { "synthetic-key" }
    func writeText(_ path: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ path: String) throws { throw CocoaError(.fileWriteNoPermission) }
}

import XCTest
@testable import OpenUsage

final class OpenAIAPIAuthStoreTests: XCTestCase {
    func testDedicatedSourcesAndAllKeyStates() throws {
        XCTAssertEqual(OpenAIAPIAuthStore.configPaths, ["~/.config/openusage/openai-api.json"])
        XCTAssertEqual(OpenAIAPIAuthStore.environmentNames, ["OPENAI_ADMIN_KEY"])
        let files = FakeFiles()
        let store = OpenAIAPIAuthStore(files: files, environment: FakeEnvironment(["OPENAI_ADMIN_KEY": " synthetic-env "]))
        XCTAssertEqual(store.loadAPIKey(), "synthetic-env")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        try store.saveAPIKey(" synthetic-saved ")
        XCTAssertEqual(store.loadAPIKey(), "synthetic-saved")
        XCTAssertEqual(store.currentAPIKey(), "synthetic-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
        try store.deleteAPIKey()
        XCTAssertEqual(store.loadAPIKey(), "synthetic-env")
        let saved = OpenAIAPIAuthStore(
            files: FakeFiles([OpenAIAPIAuthStore.configPaths[0]: #"{"api_key":"synthetic-file"}"#]),
            environment: FakeEnvironment()
        )
        XCTAssertEqual(saved.keyStatus(), .saved)
        XCTAssertEqual(saved.loadAPIKey(), "synthetic-file")
    }

    func testInferenceKeyAndOtherCredentialFilesAreNotSources() {
        let store = OpenAIAPIAuthStore(
            files: FakeFiles(["~/.config/openai/key.json": #"{"apiKey":"synthetic-other"}"#]),
            environment: FakeEnvironment(["OPENAI_API_KEY": "synthetic-inference"])
        )
        XCTAssertNil(store.loadAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testBlankAndMalformedConfigurationNeverBecomeCredentials() {
        for value in [" ", "{", #"{"apiKey":42}"#, #"{"apiKey":" "}"#] {
            let store = OpenAIAPIAuthStore(
                files: FakeFiles([OpenAIAPIAuthStore.configPaths[0]: value]),
                environment: FakeEnvironment()
            )
            XCTAssertNil(store.loadAPIKey())
        }
    }

    func testEmptySaveDoesNotWrite() {
        let files = FakeFiles()
        let store = OpenAIAPIAuthStore(files: files, environment: FakeEnvironment())
        XCTAssertThrowsError(try store.saveAPIKey(" "))
        XCTAssertTrue(files.files.isEmpty)
    }
}

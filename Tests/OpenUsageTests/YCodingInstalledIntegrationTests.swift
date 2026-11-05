import XCTest
@testable import OpenUsage

/// Opt-in contract smoke test. Reads the installed YCoding service through its public CLI only;
/// never imports credentials, forces quota probes, or prints profiles, usage values, or payloads.
@MainActor
final class YCodingInstalledIntegrationTests: XCTestCase {
    func testInstalledReadOnlyContractAndProfileMapping() async throws {
        guard ProcessInfo.processInfo.environment["OPENUSAGE_YCODING_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set OPENUSAGE_YCODING_LIVE_TEST=1 to verify the installed YCoding service.")
        }
        let client = YCodingConnectionClient(locationDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let bridge = YCodingConnectionBridge(client: client)
        let connections = try await bridge.discover()
        XCTAssertFalse(connections.isEmpty, "This opt-in smoke requires a configured supported connection.")
        XCTAssertEqual(Set(connections.map(\.cardID)).count, connections.count)
        let read = try await bridge.read(manual: false)
        XCTAssertNil(read.warning, "The installed service should provide compatible report envelopes.")
        var matched = 0
        for connection in connections {
            let snapshot = YCodingConnectionMapper.snapshot(for: connection, read: read)
            XCTAssertTrue(snapshot.providerID == connection.cardID)
            XCTAssertFalse(YCodingConnectionMapper.descriptors(for: connection).isEmpty)
            if YCodingQuotaSnapshot.matching(connection, connections: read.connections, snapshots: read.quotas) != nil {
                matched += 1
            }
        }
        XCTAssertGreaterThan(matched, 0, "At least one installed connection should have a bound quota/status snapshot.")
        print("YCoding contract smoke: \(connections.count) profiles, \(matched) bound quota/status snapshots; no forced probes.")
    }
}

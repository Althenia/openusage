import CryptoKit
import Foundation
import XCTest
@testable import OpenUsage

final class SQLiteStoreLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/synthetic-home/user", isDirectory: true)

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testDefaultRootIsLocalShareOpenUsageInHome() {
        let url = SQLiteStoreLocation.databaseURL(environment: [:], homeDirectory: home)

        XCTAssertEqual(url.path, "/synthetic-home/user/.local/share/openusage/openusage.db")
    }

    func testAbsoluteXDGDataHomeMovesTheRoot() {
        let url = SQLiteStoreLocation.databaseURL(
            environment: ["XDG_DATA_HOME": "/synthetic-data"],
            homeDirectory: home
        )

        XCTAssertEqual(url.path, "/synthetic-data/openusage/openusage.db")
    }

    func testEmptyOrRelativeXDGDataHomeIsIgnored() {
        for value in ["", "relative/data", "~/data"] {
            let url = SQLiteStoreLocation.databaseURL(
                environment: ["XDG_DATA_HOME": value],
                homeDirectory: home
            )

            XCTAssertEqual(url.path, "/synthetic-home/user/.local/share/openusage/openusage.db", value)
        }
    }

    func testProductionBundleIdentifierUsesTheDefaultFilename() {
        let explicit = SQLiteStoreLocation.databaseURL(
            environment: [:],
            homeDirectory: home,
            bundleIdentifier: "com.robinebers.openusage"
        )

        XCTAssertEqual(explicit, SQLiteStoreLocation.databaseURL(environment: [:], homeDirectory: home))
        XCTAssertEqual(explicit.lastPathComponent, "openusage.db")
    }

    func testOtherBundleIdentifiersGetHashedFilenamesInTheSameRoot() {
        let production = SQLiteStoreLocation.databaseURL(environment: [:], homeDirectory: home)
        let development = SQLiteStoreLocation.databaseURL(
            environment: [:],
            homeDirectory: home,
            bundleIdentifier: "com.robinebers.openusage.dev"
        )
        let other = SQLiteStoreLocation.databaseURL(
            environment: [:],
            homeDirectory: home,
            bundleIdentifier: "com.example.other"
        )

        XCTAssertEqual(
            development.lastPathComponent,
            "openusage-\(sha256Hex("com.robinebers.openusage.dev")).db"
        )
        XCTAssertEqual(development.lastPathComponent.count, "openusage-".count + 64 + ".db".count)
        XCTAssertNotEqual(development, other)
        XCTAssertNotEqual(development, production)
        XCTAssertEqual(development.deletingLastPathComponent(), production.deletingLastPathComponent())
        XCTAssertEqual(other.deletingLastPathComponent(), production.deletingLastPathComponent())
    }

    func testBundleIdentifierHashIsCaseSensitiveAndLowercaseHex() {
        let lower = SQLiteStoreLocation.databaseURL(
            environment: [:], homeDirectory: home, bundleIdentifier: "com.example.app"
        )
        let mixed = SQLiteStoreLocation.databaseURL(
            environment: [:], homeDirectory: home, bundleIdentifier: "com.example.App"
        )

        XCTAssertNotEqual(lower, mixed)
        XCTAssertEqual(mixed.lastPathComponent, "openusage-\(sha256Hex("com.example.App")).db")
        XCTAssertEqual(mixed.lastPathComponent, mixed.lastPathComponent.lowercased())
    }

    func testHostileBundleIdentifiersCannotEscapeTheRootOrInjectFilenames() {
        let root = SQLiteStoreLocation.databaseURL(environment: [:], homeDirectory: home)
            .deletingLastPathComponent()

        for identifier in ["../../etc/passwd", "a/b\\c", "com.example.app/../../x", " ", "../openusage"] {
            let url = SQLiteStoreLocation.databaseURL(
                environment: [:],
                homeDirectory: home,
                bundleIdentifier: identifier
            )

            XCTAssertEqual(url.deletingLastPathComponent(), root, identifier)
            XCTAssertEqual(url.lastPathComponent, "openusage-\(sha256Hex(identifier)).db", identifier)
            XCTAssertFalse(url.pathComponents.contains(".."), identifier)
        }
    }

    func testResolvingTheLocationCreatesNothingOnDisk() {
        let missingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageLocation-\(UUID().uuidString)", isDirectory: true)

        _ = SQLiteStoreLocation.databaseURL(environment: [:], homeDirectory: missingHome)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingHome.path))
    }
}

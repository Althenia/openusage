import CryptoKit
import Foundation

enum SQLiteStoreLocation {
    static let productionBundleIdentifier = "com.robinebers.openusage"

    static func databaseURL(
        environment: [String: String],
        homeDirectory: URL,
        bundleIdentifier: String = productionBundleIdentifier
    ) -> URL {
        rootDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent(fileName(bundleIdentifier: bundleIdentifier), isDirectory: false)
    }

    private static func rootDirectory(environment: [String: String], homeDirectory: URL) -> URL {
        if let configured = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("openusage", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".local/share/openusage", isDirectory: true)
    }

    private static func fileName(bundleIdentifier: String) -> String {
        guard bundleIdentifier != productionBundleIdentifier else { return "openusage.db" }
        let digest = SHA256.hash(data: Data(bundleIdentifier.utf8))
        return "openusage-" + digest.map { String(format: "%02x", $0) }.joined() + ".db"
    }
}

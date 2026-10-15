import Foundation

/// Where YCoding keeps its local database on this machine, resolved like OpenCode's data dir:
/// `$XDG_DATA_HOME/ycoding`, else `~/.local/share/ycoding`.
enum YCodingPaths {
    static func dataDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let xdg = environment.value(for: "XDG_DATA_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(xdg).trimmingTrailingSlashes + "/ycoding"
        }
        return homeDirectory.appendingPathComponent(".local/share/ycoding").path
    }

    static func databasePath(dataDirectory: String) -> String {
        dataDirectory.trimmingTrailingSlashes + "/ycoding.db"
    }
}

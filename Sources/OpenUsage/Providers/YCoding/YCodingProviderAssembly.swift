import Foundation

@MainActor
struct YCodingProviderAssembly {
    let providers: [ProviderRuntime]
    let identityKeysByCard: [String: String]

    nonisolated static func defaultServiceFilePath(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        YCodingPaths.serviceFilePath(
            stateDirectory: YCodingPaths.stateDirectory(environment: environment, homeDirectory: homeDirectory)
        )
    }

    static func make(client: (any YCodingConnectionReading)? = nil) async -> Self {
        if client == nil, !isInstalled { return Self(providers: [], identityKeysByCard: [:]) }
        let bridge = YCodingConnectionBridge(client: client ?? YCodingConnectionClient(
            locationDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            serviceFilePath: defaultServiceFilePath()
        ))
        do {
            let connections = try await bridge.discover()
            let providers = connections.map { YCodingConnectionProvider(connection: $0, bridge: bridge) }
            // The public API has no account-generation stamp. Never paint a previous launch's
            // quota after someone has replaced the login while retaining the same profile name/id.
            let launch = UUID().uuidString
            let identities = Dictionary(uniqueKeysWithValues: connections.map { ($0.cardID, launch) })
            return Self(providers: providers, identityKeysByCard: identities)
        } catch {
            AppLog.error("plugin:ycoding", "YCoding connection discovery failed; legacy credential fallback is disabled")
            return Self(providers: [YCodingDiscoveryFailureProvider()], identityKeysByCard: [:])
        }
    }

    private static var isInstalled: Bool {
        if FileManager.default.fileExists(atPath: defaultServiceFilePath()) { return true }
        let executable = YCodingConnectionClient.defaultExecutable()
        if executable != "ycoding" { return true }
        return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: String($0) + "/ycoding")
        }
    }
}

/// A failed discovery must remain visible rather than silently importing an unrelated default login.
@MainActor
private final class YCodingDiscoveryFailureProvider: ProviderRuntime {
    let provider = Provider(id: "codex@ycoding-unavailable", displayName: "YCoding", icon: .providerMark("codex"))
    var widgetDescriptors: [WidgetDescriptor] {
        [.percent(id: "\(provider.id).session", provider: provider, title: "Session")]
    }
    func hasLocalCredentials() async -> Bool { true }
    func refresh() async -> ProviderSnapshot {
        .error(provider: provider,
               message: "YCoding connections could not be loaded. Open YCoding, then restart OpenUsage.",
               category: .notAvailable)
    }
}

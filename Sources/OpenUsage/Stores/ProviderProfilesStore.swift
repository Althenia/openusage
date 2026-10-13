import Foundation
import Observation

struct ProviderProfile: Codable, Equatable, Identifiable, Sendable {
    enum Family: String, Codable, CaseIterable, Sendable {
        case claude
        case codex

        var displayName: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }
    }

    var id: UUID
    var family: Family
    var name: String
    var directory: String
}

enum ProviderProfileError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case missingFolder

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a profile name."
        case .duplicateName: "A profile with that name already exists."
        case .missingFolder: "That folder doesn't exist. Choose another folder."
        }
    }
}

@MainActor
@Observable
final class ProviderProfilesStore {
    static let storageKey = "openusage.providerProfiles.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directoryExists: (String) -> Bool
    @ObservationIgnored private let launchProfiles: [ProviderProfile]
    private(set) var profiles: [ProviderProfile]

    var needsRelaunch: Bool { profiles != launchProfiles }

    init(
        defaults: UserDefaults = .standard,
        directoryExists: @escaping (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) {
        self.defaults = defaults
        self.directoryExists = directoryExists
        let loaded = Self.load(from: defaults)
        self.profiles = loaded
        self.launchProfiles = loaded
    }

    static func load(from defaults: UserDefaults) -> [ProviderProfile] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([ProviderProfile].self, from: data)
        } catch {
            AppLog.error(.config, "provider profiles were undecodable; starting with none: \(error.localizedDescription)")
            return []
        }
    }

    func profiles(for family: ProviderProfile.Family) -> [ProviderProfile] {
        profiles.filter { $0.family == family }
    }

    func add(family: ProviderProfile.Family, name: String, directory: String) throws {
        let name = try validatedName(name, family: family, excluding: nil)
        let path = try validatedDirectory(directory)
        profiles.append(ProviderProfile(id: UUID(), family: family, name: name, directory: path))
        persist()
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = try validatedName(name, family: profiles[index].family, excluding: id)
        persist()
    }

    func changeDirectory(_ id: UUID, to directory: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].directory = try validatedDirectory(directory)
        persist()
    }

    func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    private func validatedName(_ raw: String, family: ProviderProfile.Family, excluding id: UUID?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProviderProfileError.emptyName }
        guard !profiles.contains(where: {
            $0.family == family && $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw ProviderProfileError.duplicateName }
        return name
    }

    private func validatedDirectory(_ raw: String) throws -> String {
        let path = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.path.trimmingTrailingSlashes
        guard directoryExists(path) else { throw ProviderProfileError.missingFolder }
        return path
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: Self.storageKey)
        } catch {
            AppLog.error(.config, "failed to save provider profiles: \(error.localizedDescription)")
        }
    }
}

import XCTest
@testable import OpenUsage

@MainActor
final class ProviderProfilesStoreTests: XCTestCase {
    private let folders: Set<String> = ["/Users/dev/claude-work", "/Users/dev/codex-work", "/Users/dev/other"]

    private func makeStore(_ defaults: UserDefaults) -> ProviderProfilesStore {
        ProviderProfilesStore(defaults: defaults, directoryExists: { [folders] in folders.contains($0) })
    }

    func testAddedProfilesPersistTrimmedAndStandardized() throws {
        let defaults = makeScratchDefaults("ProviderProfiles")
        let store = makeStore(defaults)

        try store.add(family: .claude, name: "  Work ", directory: "/Users/dev/claude-work/")
        try store.add(family: .codex, name: "Work", directory: "/Users/dev/codex-work")

        let reloaded = makeStore(defaults)
        XCTAssertEqual(reloaded.profiles, store.profiles)
        XCTAssertEqual(reloaded.profiles(for: .claude).map(\.name), ["Work"])
        XCTAssertEqual(reloaded.profiles(for: .claude).map(\.directory), ["/Users/dev/claude-work"])
        XCTAssertEqual(reloaded.profiles(for: .codex).map(\.directory), ["/Users/dev/codex-work"])
    }

    func testAddRejectsEmptyDuplicateAndMissingFolderWithoutSaving() throws {
        let defaults = makeScratchDefaults("ProviderProfiles")
        let store = makeStore(defaults)
        try store.add(family: .claude, name: "Work", directory: "/Users/dev/claude-work")

        XCTAssertThrowsError(try store.add(family: .claude, name: "   ", directory: "/Users/dev/other")) {
            XCTAssertEqual($0 as? ProviderProfileError, .emptyName)
        }
        XCTAssertThrowsError(try store.add(family: .claude, name: " work ", directory: "/Users/dev/other")) {
            XCTAssertEqual($0 as? ProviderProfileError, .duplicateName)
        }
        XCTAssertThrowsError(try store.add(family: .claude, name: "Other", directory: "/Users/dev/missing")) {
            XCTAssertEqual($0 as? ProviderProfileError, .missingFolder)
        }
        XCTAssertEqual(makeStore(defaults).profiles.map(\.name), ["Work"])
        XCTAssertEqual(ProviderProfileError.missingFolder.errorDescription, "That folder doesn't exist. Choose another folder.")
    }

    func testRenameValidatesWithinItsProviderAndPersists() throws {
        let defaults = makeScratchDefaults("ProviderProfiles")
        let store = makeStore(defaults)
        try store.add(family: .claude, name: "Work", directory: "/Users/dev/claude-work")
        try store.add(family: .claude, name: "Home", directory: "/Users/dev/other")
        try store.add(family: .codex, name: "Office", directory: "/Users/dev/codex-work")
        let work = try XCTUnwrap(store.profiles(for: .claude).first)

        XCTAssertThrowsError(try store.rename(work.id, to: "home")) {
            XCTAssertEqual($0 as? ProviderProfileError, .duplicateName)
        }
        XCTAssertThrowsError(try store.rename(work.id, to: " ")) {
            XCTAssertEqual($0 as? ProviderProfileError, .emptyName)
        }
        try store.rename(work.id, to: "WORK")
        try store.rename(work.id, to: "Office")

        XCTAssertEqual(makeStore(defaults).profiles(for: .claude).map(\.name), ["Office", "Home"])
    }

    func testRemoveDeletesOnlyThatProfileAndTracksPendingRelaunch() throws {
        let defaults = makeScratchDefaults("ProviderProfiles")
        let store = makeStore(defaults)
        try store.add(family: .claude, name: "Work", directory: "/Users/dev/claude-work")

        let launched = makeStore(defaults)
        XCTAssertFalse(launched.needsRelaunch)
        try launched.add(family: .codex, name: "Work", directory: "/Users/dev/codex-work")
        XCTAssertTrue(launched.needsRelaunch)
        let codex = try XCTUnwrap(launched.profiles(for: .codex).first)
        launched.remove(codex.id)
        XCTAssertFalse(launched.needsRelaunch)
        let claude = try XCTUnwrap(launched.profiles(for: .claude).first)
        launched.remove(claude.id)

        XCTAssertTrue(launched.needsRelaunch)
        XCTAssertTrue(makeStore(defaults).profiles.isEmpty)
    }

    func testChangeDirectoryStandardizesPersistsAndKeepsTheProfile() throws {
        let defaults = makeScratchDefaults("ProviderProfiles")
        let store = makeStore(defaults)
        try store.add(family: .claude, name: "Work", directory: "/Users/dev/claude-work")
        try store.add(family: .codex, name: "Work", directory: "/Users/dev/codex-work")
        let claude = try XCTUnwrap(store.profiles(for: .claude).first)

        try store.changeDirectory(claude.id, to: " /Users/dev/other/ ")
        try store.rename(claude.id, to: "Office")

        let reloaded = makeStore(defaults)
        XCTAssertEqual(reloaded.profiles(for: .claude), [
            ProviderProfile(id: claude.id, family: .claude, name: "Office", directory: "/Users/dev/other"),
        ])
        XCTAssertEqual(reloaded.profiles(for: .codex).map(\.directory), ["/Users/dev/codex-work"])
    }

    func testChangeDirectoryRejectsMissingFolderWithoutSaving() throws {
        let defaults = makeScratchDefaults("ProviderProfiles")
        let store = makeStore(defaults)
        try store.add(family: .claude, name: "Work", directory: "/Users/dev/claude-work")
        let profile = try XCTUnwrap(store.profiles.first)

        XCTAssertThrowsError(try store.changeDirectory(profile.id, to: "/Users/dev/missing")) {
            XCTAssertEqual($0 as? ProviderProfileError, .missingFolder)
        }
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertEqual(makeStore(defaults).profiles, [profile])
    }

    func testChangeDirectoryTracksPendingRelaunch() throws {
        let defaults = makeScratchDefaults("ProviderProfiles")
        try makeStore(defaults).add(family: .claude, name: "Work", directory: "/Users/dev/claude-work")
        let launched = makeStore(defaults)
        let profile = try XCTUnwrap(launched.profiles.first)

        try launched.changeDirectory(profile.id, to: "/Users/dev/other")
        XCTAssertTrue(launched.needsRelaunch)
        try launched.changeDirectory(profile.id, to: "/Users/dev/claude-work")
        XCTAssertFalse(launched.needsRelaunch)
    }

    func testUndecodableStorageStartsEmpty() {
        let defaults = makeScratchDefaults("ProviderProfiles")
        defaults.set(Data("not json".utf8), forKey: ProviderProfilesStore.storageKey)

        XCTAssertTrue(makeStore(defaults).profiles.isEmpty)
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

private enum StoredMode: String {
    case first
    case second
}

@MainActor
private final class StorageProbe {
    var flag: Bool?
    var text: String?
    var mode: StoredMode?
    var flagBinding: Binding<Bool>?
    var modeBinding: Binding<StoredMode>?
}

private struct StorageProbeView: View {
    let probe: StorageProbe
    @SQLiteStorage("probe.flag") private var flag = false
    @SQLiteStorage("probe.text") private var text = "default-text"
    @SQLiteStorage("probe.mode") private var mode = StoredMode.first

    var body: some View {
        let _ = capture()
        return Color.clear.frame(width: 4, height: 4)
    }

    private func capture() {
        probe.flag = flag
        probe.text = text
        probe.mode = mode
        probe.flagBinding = $flag
        probe.modeBinding = $mode
    }
}

private final class NotificationCounter: @unchecked Sendable {
    var value = 0
}

@MainActor
final class AppPreferencesTests: XCTestCase {
    private struct Probe: Error {}

    private var directory: URL!
    private var databaseURL: URL!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        directory = try StorageTestDirectory.make()
        databaseURL = directory.appendingPathComponent("store.db")
        store = try SQLiteStore(url: databaseURL)
    }

    override func tearDownWithError() throws {
        AppPreferences.unconfigureStandard()
        try? FileManager.default.removeItem(at: directory)
    }

    private func preferences(_ namespace: String = "app", store override: SQLiteStore? = nil) -> AppPreferences {
        AppPreferences(store: override ?? store, namespace: namespace)
    }

    func testTypedValuesRoundTripAcrossFreshStoreAndPreferencesInstances() throws {
        let writer = preferences()
        writer.set("text", forKey: "string")
        writer.set(true, forKey: "bool")
        writer.set(7, forKey: "integer")
        writer.set(2.5, forKey: "double")
        writer.set(Data([0, 1, 2, 255]), forKey: "data")
        writer.set(["a", "b"], forKey: "strings")
        writer.set(["a", 2, 3.5] as [Any], forKey: "array")
        writer.set(["name": "x", "count": 3, "nested": ["k": "v"]] as [String: Any], forKey: "dictionary")

        let reader = preferences(store: try SQLiteStore(url: databaseURL))

        XCTAssertEqual(reader.string(forKey: "string"), "text")
        XCTAssertEqual(reader.bool(forKey: "bool"), true)
        XCTAssertEqual(reader.integer(forKey: "integer"), 7)
        XCTAssertEqual(reader.double(forKey: "double"), 2.5)
        XCTAssertEqual(reader.data(forKey: "data"), Data([0, 1, 2, 255]))
        XCTAssertEqual(reader.stringArray(forKey: "strings"), ["a", "b"])
        XCTAssertEqual(reader.array(forKey: "array") as NSArray?, ["a", 2, 3.5] as NSArray)
        XCTAssertEqual(
            reader.dictionary(forKey: "dictionary") as NSDictionary?,
            ["name": "x", "count": 3, "nested": ["k": "v"]] as NSDictionary
        )
        XCTAssertEqual(reader.object(forKey: "string") as? String, "text")
    }

    func testAbsentKeysAreNilWhileFalseZeroAndEmptyValuesAreStored() {
        let prefs = preferences()

        XCTAssertNil(prefs.object(forKey: "flag"))
        XCTAssertNil(prefs.string(forKey: "flag"))
        XCTAssertNil(prefs.data(forKey: "flag"))
        XCTAssertNil(prefs.stringArray(forKey: "flag"))
        XCTAssertFalse(prefs.bool(forKey: "flag"))
        XCTAssertEqual(prefs.integer(forKey: "flag"), 0)
        XCTAssertEqual(prefs.double(forKey: "flag"), 0)

        prefs.set(false, forKey: "flag")
        prefs.set(0, forKey: "count")
        prefs.set("", forKey: "text")
        prefs.set([String](), forKey: "list")

        XCTAssertEqual(prefs.object(forKey: "flag") as? Bool, false)
        XCTAssertEqual(prefs.object(forKey: "count") as? Int, 0)
        XCTAssertEqual(prefs.string(forKey: "text"), "")
        XCTAssertEqual(prefs.stringArray(forKey: "list"), [])
    }

    func testRemoveObjectMakesTheKeyAbsentAndPersists() throws {
        let prefs = preferences()
        prefs.set("value", forKey: "key")
        prefs.set("other", forKey: "kept")

        prefs.removeObject(forKey: "key")

        XCTAssertNil(prefs.object(forKey: "key"))
        XCTAssertNil(preferences(store: try SQLiteStore(url: databaseURL)).object(forKey: "key"))
        XCTAssertEqual(prefs.string(forKey: "kept"), "other")
    }

    func testNamespacesAreIsolatedAndResettingOneLeavesTheOther() throws {
        let app = preferences("app")
        let telemetry = preferences("telemetry")
        app.set("app-value", forKey: "shared")
        telemetry.set("telemetry-value", forKey: "shared")
        telemetry.set("install-1", forKey: "installID")

        XCTAssertEqual(app.string(forKey: "shared"), "app-value")
        XCTAssertEqual(telemetry.string(forKey: "shared"), "telemetry-value")

        try store.removeNamespace("app")

        XCTAssertNil(app.string(forKey: "shared"))
        XCTAssertEqual(telemetry.string(forKey: "shared"), "telemetry-value")
        XCTAssertEqual(telemetry.string(forKey: "installID"), "install-1")
    }

    func testIsEmptyReflectsStoredKeysInItsNamespaceOnly() {
        let app = preferences("app")
        let telemetry = preferences("telemetry")
        XCTAssertTrue(app.isEmpty)

        telemetry.set("x", forKey: "key")
        XCTAssertTrue(app.isEmpty)
        XCTAssertFalse(telemetry.isEmpty)

        app.set("x", forKey: "key")
        XCTAssertFalse(app.isEmpty)

        app.removeObject(forKey: "key")
        XCTAssertTrue(app.isEmpty)
    }

    func testTrySetRejectsUnsupportedValuesWithoutChangingStoredState() {
        let prefs = preferences()
        prefs.set("before", forKey: "key")

        XCTAssertThrowsError(try prefs.trySet(NSObject(), forKey: "key"))

        XCTAssertEqual(prefs.string(forKey: "key"), "before")
        XCTAssertThrowsError(try prefs.trySet(NSObject(), forKey: "new"))
        XCTAssertNil(prefs.object(forKey: "new"))
    }

    func testNonThrowingSetOfUnsupportedValuePostsErrorNotificationAndKeepsState() {
        let prefs = preferences()
        prefs.set("before", forKey: "key")
        let posted = expectation(forNotification: AppPreferences.errorDidChangeNotification, object: nil)

        prefs.set(NSObject(), forKey: "key")

        wait(for: [posted], timeout: 2)
        XCTAssertEqual(prefs.string(forKey: "key"), "before")
    }

    func testThrowingTransactionRollsBackEveryPreferenceWrite() throws {
        let prefs = preferences()
        prefs.set("before", forKey: "existing")

        XCTAssertThrowsError(try prefs.transaction { transactional in
            transactional.set("changed", forKey: "existing")
            try transactional.trySet("new", forKey: "added")
            transactional.removeObject(forKey: "existing")
            throw Probe()
        }) { XCTAssertTrue($0 is Probe) }

        XCTAssertEqual(prefs.string(forKey: "existing"), "before")
        XCTAssertNil(prefs.object(forKey: "added"))
    }

    func testSuccessfulTransactionCommitsAndReturnsValue() throws {
        let prefs = preferences()

        let result = try prefs.transaction { transactional -> String in
            transactional.set("one", forKey: "a")
            transactional.set("two", forKey: "b")
            return "done"
        }

        XCTAssertEqual(result, "done")
        XCTAssertEqual(prefs.string(forKey: "a"), "one")
        XCTAssertEqual(prefs.string(forKey: "b"), "two")
    }

    func testWritesPostDidChangeNotificationAndReadsDoNot() {
        let prefs = preferences()
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: AppPreferences.didChangeNotification, object: nil, queue: nil
        ) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = prefs.string(forKey: "key")
        _ = prefs.isEmpty
        XCTAssertEqual(counter.value, 0)

        prefs.set("value", forKey: "key")
        XCTAssertGreaterThanOrEqual(counter.value, 1)

        let afterSet = counter.value
        prefs.removeObject(forKey: "key")
        XCTAssertGreaterThan(counter.value, afterSet)
    }

    func testUnconfiguredStandardIsStoreLess() {
        AppPreferences.unconfigureStandard()

        XCTAssertNil(AppPreferences.standard.object(forKey: "key"))
        XCTAssertNil(AppPreferences.standard.string(forKey: "key"))
        XCTAssertFalse(AppPreferences.standard.bool(forKey: "key"))
        XCTAssertTrue(AppPreferences.standard.isEmpty)
    }

    func testConfiguredStandardReadsAndWritesTheProvidedStore() throws {
        let prefs = preferences()
        prefs.set("configured", forKey: "key")

        AppPreferences.configureStandard(prefs)
        XCTAssertEqual(AppPreferences.standard.string(forKey: "key"), "configured")

        AppPreferences.standard.set("through-standard", forKey: "other")
        XCTAssertEqual(prefs.string(forKey: "other"), "through-standard")

        AppPreferences.unconfigureStandard()
        XCTAssertNil(AppPreferences.standard.string(forKey: "key"))
    }

    func testSQLiteStorageReadsDefaultsStoredValuesAndFallsBackOnUnknownEnumRaw() throws {
        let prefs = preferences()
        let probe = StorageProbe()
        func render() throws {
            let renderer = ImageRenderer(content: StorageProbeView(probe: probe).environment(\.appPreferences, prefs))
            renderer.scale = 1
            _ = try XCTUnwrap(renderer.cgImage)
        }

        try render()
        XCTAssertEqual(probe.flag, false)
        XCTAssertEqual(probe.text, "default-text")
        XCTAssertEqual(probe.mode, .first)

        prefs.set(true, forKey: "probe.flag")
        prefs.set("stored-text", forKey: "probe.text")
        prefs.set("second", forKey: "probe.mode")
        try render()
        XCTAssertEqual(probe.flag, true)
        XCTAssertEqual(probe.text, "stored-text")
        XCTAssertEqual(probe.mode, .second)

        prefs.set("not-a-mode", forKey: "probe.mode")
        try render()
        XCTAssertEqual(probe.mode, .first)
    }

    func testSQLiteStorageBindingsWriteThroughTheInjectedPreferences() throws {
        let prefs = preferences()
        let probe = StorageProbe()
        let renderer = ImageRenderer(content: StorageProbeView(probe: probe).environment(\.appPreferences, prefs))
        renderer.scale = 1
        _ = try XCTUnwrap(renderer.cgImage)

        probe.flagBinding?.wrappedValue = true
        probe.modeBinding?.wrappedValue = .second

        XCTAssertEqual(prefs.object(forKey: "probe.flag") as? Bool, true)
        XCTAssertEqual(prefs.string(forKey: "probe.mode"), "second")
    }
}

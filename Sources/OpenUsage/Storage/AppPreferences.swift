import Foundation
import os

final class AppPreferences: Sendable {
    static let didChangeNotification = Notification.Name("AppPreferencesDidChange")
    static let errorDidChangeNotification = Notification.Name("AppPreferencesErrorDidChange")
    static let namespaceUserInfoKey = "namespace"
    static let keyUserInfoKey = "key"
    static let appNamespace = "app"
    static let telemetryNamespace = "telemetry"

    private struct State: Sendable {
        var lastError: SQLiteStoreError?
        var loggedNotConfigured = false
        var defersNotifications = false
        var pendingKeys: [String] = []
    }

    private struct Shared: Sendable {
        var standard: AppPreferences
        var telemetry: AppPreferences
    }

    private static let shared = OSAllocatedUnfairLock(initialState: Shared(
        standard: AppPreferences(inertNamespace: appNamespace),
        telemetry: AppPreferences(inertNamespace: telemetryNamespace)
    ))

    let store: SQLiteStore?
    let namespace: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(store: SQLiteStore, namespace: String) {
        self.store = store
        self.namespace = namespace
    }

    private init(inertNamespace: String) {
        self.store = nil
        self.namespace = inertNamespace
    }

    static var standard: AppPreferences { shared.withLock { $0.standard } }
    static var telemetry: AppPreferences { shared.withLock { $0.telemetry } }

    static func configureStandard(_ preferences: AppPreferences) {
        let telemetry = preferences.store.map { AppPreferences(store: $0, namespace: telemetryNamespace) }
            ?? AppPreferences(inertNamespace: telemetryNamespace)
        shared.withLock {
            $0.standard = preferences
            $0.telemetry = telemetry
        }
    }

    static func unconfigureStandard() {
        shared.withLock {
            $0.standard = AppPreferences(inertNamespace: appNamespace)
            $0.telemetry = AppPreferences(inertNamespace: telemetryNamespace)
        }
    }

    var lastError: SQLiteStoreError? {
        state.withLock { $0.lastError }
    }

    func checkError() throws {
        if let error = lastError { throw error }
    }

    var isEmpty: Bool {
        guard let store else {
            record(SQLiteStoreError.notConfigured)
            return true
        }
        do {
            return try store.keys(namespace: namespace).isEmpty
        } catch {
            record(error)
            return false
        }
    }

    func object(forKey key: String) -> Any? {
        guard let store else {
            record(SQLiteStoreError.notConfigured)
            return nil
        }
        do {
            guard let data = try store.data(namespace: namespace, key: key) else { return nil }
            return try Self.decode(data)
        } catch {
            record(error)
            return nil
        }
    }

    func set(_ value: Any?, forKey key: String) {
        do {
            try write(value, forKey: key)
        } catch {
            record(error)
        }
    }

    func trySet(_ value: Any?, forKey key: String) throws {
        do {
            try write(value, forKey: key)
        } catch {
            record(error)
            throw error
        }
    }

    func removeObject(forKey key: String) {
        set(nil, forKey: key)
    }

    func transaction<T>(_ body: (AppPreferences) throws -> T) throws -> T {
        guard let store else {
            record(SQLiteStoreError.notConfigured)
            throw SQLiteStoreError.notConfigured
        }
        let scoped = AppPreferences(store: store, namespace: namespace)
        scoped.state.withLock { $0.defersNotifications = true }
        let result: T
        do {
            result = try store.transaction { _ -> T in
                let value = try body(scoped)
                try scoped.checkError()
                return value
            }
        } catch {
            if let storeError = error as? SQLiteStoreError { record(storeError) }
            throw error
        }
        var posted = Set<String>()
        for key in scoped.state.withLock({ $0.pendingKeys }) where posted.insert(key).inserted {
            postChange(key)
        }
        return result
    }

    private func write(_ value: Any?, forKey key: String) throws {
        guard let store else { throw SQLiteStoreError.notConfigured }
        if let value {
            let wrapped: [Any] = [value]
            guard PropertyListSerialization.propertyList(wrapped, isValidFor: .binary) else {
                throw SQLiteStoreError.invalidValue
            }
            let data = try PropertyListSerialization.data(fromPropertyList: wrapped, format: .binary, options: 0)
            try store.set(data, namespace: namespace, key: key)
        } else {
            try store.remove(namespace: namespace, key: key)
        }
        didWrite(key, in: store)
    }

    private func didWrite(_ key: String, in store: SQLiteStore) {
        let deferred = state.withLock { state -> Bool in
            guard state.defersNotifications else { return false }
            state.pendingKeys.append(key)
            return true
        }
        if deferred || store.isInTransaction { return }
        postChange(key)
    }

    private func postChange(_ key: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.namespaceUserInfoKey: namespace, Self.keyUserInfoKey: key]
        )
    }

    private func record(_ error: Error) {
        let storeError = (error as? SQLiteStoreError) ?? .invalidValue
        let shouldLog = state.withLock { state -> Bool in
            state.lastError = storeError
            guard storeError == .notConfigured else { return true }
            defer { state.loggedNotConfigured = true }
            return !state.loggedNotConfigured
        }
        if shouldLog {
            AppLog.error(.config, "preferences (\(namespace)): \(storeError.logDescription)")
        }
        NotificationCenter.default.post(name: Self.errorDidChangeNotification, object: self)
    }

    private static func decode(_ data: Data) throws -> Any {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let wrapped = object as? [Any], wrapped.count == 1 else { throw SQLiteStoreError.invalidValue }
        return wrapped[0]
    }
}

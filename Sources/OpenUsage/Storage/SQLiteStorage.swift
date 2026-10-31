import Foundation
import SwiftUI

private struct AppPreferencesEnvironmentKey: EnvironmentKey {
    static var defaultValue: AppPreferences { .standard }
}

extension EnvironmentValues {
    var appPreferences: AppPreferences {
        get { self[AppPreferencesEnvironmentKey.self] }
        set { self[AppPreferencesEnvironmentKey.self] = newValue }
    }
}

@MainActor
private final class PreferenceObserver: NSObject, ObservableObject {
    private var observedNamespace: String?
    private var observedKey: String?

    func observe(namespace: String, key: String) {
        guard observedNamespace != namespace || observedKey != key else { return }
        NotificationCenter.default.removeObserver(self, name: AppPreferences.didChangeNotification, object: nil)
        observedNamespace = namespace
        observedKey = key
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferenceDidChange(_:)),
            name: AppPreferences.didChangeNotification,
            object: nil
        )
    }

    @objc private nonisolated func preferenceDidChange(_ notification: Notification) {
        let namespace = notification.userInfo?[AppPreferences.namespaceUserInfoKey] as? String
        let key = notification.userInfo?[AppPreferences.keyUserInfoKey] as? String
        Task { @MainActor in
            self.handleChange(namespace: namespace, key: key)
        }
    }

    private func handleChange(namespace: String?, key: String?) {
        guard namespace == observedNamespace, key == observedKey else { return }
        objectWillChange.send()
    }
}

@MainActor
@propertyWrapper
struct SQLiteStorage<Value: Sendable>: @MainActor DynamicProperty {
    @Environment(\.appPreferences) private var environmentPreferences
    @StateObject private var observer = PreferenceObserver()

    private let key: String
    private let defaultValue: Value
    private let explicitPreferences: AppPreferences?
    private let read: @Sendable (AppPreferences, String, Value) -> Value
    private let write: @Sendable (AppPreferences, String, Value) -> Void

    fileprivate init(
        key: String,
        defaultValue: Value,
        store: AppPreferences?,
        read: @escaping @Sendable (AppPreferences, String, Value) -> Value,
        write: @escaping @Sendable (AppPreferences, String, Value) -> Void
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.explicitPreferences = store
        self.read = read
        self.write = write
    }

    private var preferences: AppPreferences {
        explicitPreferences ?? environmentPreferences
    }

    var wrappedValue: Value {
        get { read(preferences, key, defaultValue) }
        nonmutating set { write(preferences, key, newValue) }
    }

    var projectedValue: Binding<Value> {
        let resolved = self.preferences
        let storedKey = self.key
        let fallback = self.defaultValue
        let reader = self.read
        let writer = self.write
        return Binding(
            get: { reader(resolved, storedKey, fallback) },
            set: { writer(resolved, storedKey, $0) }
        )
    }

    func update() {
        observer.observe(namespace: preferences.namespace, key: key)
    }
}

extension SQLiteStorage where Value == Bool {
    init(wrappedValue: Bool, _ key: String, store: AppPreferences? = nil) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            store: store,
            read: { $0.bool(forKey: $1, default: $2) },
            write: { $0.set($2, forKey: $1) }
        )
    }
}

extension SQLiteStorage where Value == String {
    init(wrappedValue: String, _ key: String, store: AppPreferences? = nil) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            store: store,
            read: { $0.string(forKey: $1) ?? $2 },
            write: { $0.set($2, forKey: $1) }
        )
    }
}

extension SQLiteStorage where Value: RawRepresentable, Value.RawValue == String {
    init(wrappedValue: Value, _ key: String, store: AppPreferences? = nil) {
        self.init(
            key: key,
            defaultValue: wrappedValue,
            store: store,
            read: { $0.enumValue(forKey: $1, default: $2) },
            write: { $0.set($2.rawValue, forKey: $1) }
        )
    }
}

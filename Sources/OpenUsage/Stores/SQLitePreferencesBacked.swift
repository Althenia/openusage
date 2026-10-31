import Foundation

protocol SQLitePreferencesBacked: RawRepresentable where RawValue == String {
    static var key: String { get }
    static var fallback: Self { get }
}

extension SQLitePreferencesBacked {
    static var current: Self {
        AppPreferences.standard.enumValue(forKey: key, default: fallback)
    }
}

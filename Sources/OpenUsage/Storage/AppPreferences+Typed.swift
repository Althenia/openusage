import Foundation

extension AppPreferences {
    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }

    func array(forKey key: String) -> [Any]? {
        object(forKey: key) as? [Any]
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        object(forKey: key) as? [String: Any]
    }

    func stringArray(forKey key: String) -> [String]? {
        guard let values = array(forKey: key) else { return nil }
        let strings = values.compactMap { $0 as? String }
        return strings.count == values.count ? strings : nil
    }

    func bool(forKey key: String) -> Bool {
        bool(forKey: key, default: false)
    }

    func bool(forKey key: String, default fallback: Bool) -> Bool {
        (object(forKey: key) as? NSNumber)?.boolValue ?? fallback
    }

    func integer(forKey key: String) -> Int {
        (object(forKey: key) as? NSNumber)?.intValue ?? 0
    }

    func double(forKey key: String) -> Double {
        (object(forKey: key) as? NSNumber)?.doubleValue ?? 0
    }

    func enumValue<T: RawRepresentable>(forKey key: String, default fallback: T) -> T where T.RawValue == String {
        string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}

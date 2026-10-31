import Foundation

enum LegacyJSONShape {
    case array
    case object
}

enum LegacyValueKind {
    case string
    case bool
    case integer
    case number
    case stringArray
    case json(LegacyJSONShape)

    func validated(_ raw: Any, key: String) throws -> Any {
        switch self {
        case .string:
            guard let value = raw as? String else { throw LegacyImportError.malformed(key) }
            return value
        case .bool:
            guard let number = raw as? NSNumber, Self.isBool(number) else {
                throw LegacyImportError.malformed(key)
            }
            return number.boolValue
        case .integer:
            guard let number = raw as? NSNumber, !Self.isBool(number), !CFNumberIsFloatType(number as CFNumber) else {
                throw LegacyImportError.malformed(key)
            }
            return number.intValue
        case .number:
            guard let number = raw as? NSNumber, !Self.isBool(number) else {
                throw LegacyImportError.malformed(key)
            }
            return CFNumberIsFloatType(number as CFNumber) ? number.doubleValue : number.intValue
        case .stringArray:
            guard let value = raw as? [String] else { throw LegacyImportError.malformed(key) }
            return value
        case .json(let shape):
            guard let data = raw as? Data,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  Self.matches(object, shape)
            else { throw LegacyImportError.malformed(key) }
            return data
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func matches(_ object: Any, _ shape: LegacyJSONShape) -> Bool {
        switch shape {
        case .array: object is [Any]
        case .object: object is [String: Any]
        }
    }
}

enum LegacyImportKeys {
    static let applicationNamespace = "app"
    static let telemetryNamespace = "telemetry"

    static let telemetry: [String: LegacyValueKind] = [
        "installID": .string,
        "enabled": .bool,
        "activeDay": .string,
        "providerDays": .json(.object)
    ]

    private static let layout = "openusage.layout.v1"

    static let application: [String: LegacyValueKind] = [
        "appearance": .string,
        "timeFormat": .string,
        "density": .string,
        "logLevel": .string,
        "meterStyle": .string,
        "resetDisplayMode": .string,
        "copilot.billingOrg": .string,
        "reduceAnimations": .bool,
        "showTotalSpend": .bool,
        "alwaysShowPacing": .bool,
        "increaseTransparency": .bool,
        "hideUsageWhileScreenSharing": .bool,
        "betaUpdatesEnabled": .bool,
        "openusage.settings.schemaVersion": .integer,
        "openusage.enabledProviders.v1": .stringArray,
        "openusage.disabledProviders.v1": .stringArray,
        "openusage.knownProviders.v1": .stringArray,
        "openusage.providerProfiles.v1": .json(.array),
        "openusage.providerAccounts.v1": .json(.array),
        "openusage.shellEnvSnapshot.v2": .json(.object),
        "openusage.providerSnapshots.v9": .json(.object),
        layout: .json(.array),
        "\(layout).providerOrder": .json(.array),
        "\(layout).metricOrderByProvider": .json(.object),
        "\(layout).seededDefaults": .json(.array),
        "\(layout).menuBarPins": .stringArray,
        "\(layout).expandedMetrics": .stringArray,
        "\(layout).expandOnEnable": .stringArray,
        "\(layout).expandedProviders": .stringArray,
        "\(layout).menuBarStyle": .string,
        "openusage.panel.height.dashboard": .number,
        "openusage.panel.height.customize": .number,
        "openusage.panel.height.settings": .number,
        "openusage.notifications.underTenPercent": .bool,
        "openusage.notifications.healthyToClose": .bool,
        "openusage.notifications.closeToRunningOut": .bool,
        "openusage.onboarding.welcomePending": .bool,
        "openusage.onboarding.customizeHintPending": .bool,
        "openusage.icloudSync.enabled.v1": .bool,
        "openusage.icloudSync.deviceID.v1": .string,
        "openusage.codex.fallbackModel": .string,
        "openusage.totalSpend.period": .string,
        "openusage.totalSpend.metric": .string
    ]
}

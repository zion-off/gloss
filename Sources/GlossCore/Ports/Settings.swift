import Foundation

/// A typed setting. Owners declare their keys next to the code that uses them.
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Typed access to settings stored as JSON in the library.
public struct SettingsCodec: Sendable {
    public init() {}

    public func value<V>(_ key: SettingKey<V>, in reading: any SettingsReading) throws -> V {
        guard let data = try reading.rawSetting(key.name) else { return key.defaultValue }
        do {
            return try JSONDecoder().decode(Wrapper<V>.self, from: data).value
        } catch {
            return key.defaultValue
        }
    }

    public func set<V>(_ value: V?, for key: SettingKey<V>, in repository: any SettingsRepository, at date: Date) throws {
        let data = try value.map { try JSONEncoder().encode(Wrapper(value: $0)) }
        try repository.setRawSetting(data, for: key.name, at: date)
    }

    /// Wrapping keeps top-level scalars valid JSON for every decoder.
    private struct Wrapper<V: Codable>: Codable { var value: V }
}

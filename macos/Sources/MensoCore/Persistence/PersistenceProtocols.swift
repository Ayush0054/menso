import Foundation

public protocol SettingsPersisting: Sendable {
    func data(forKey key: String) async throws -> Data?
    func saveData(_ data: Data, forKey key: String) async throws
}

/// Settings can fall back to memory; action execution must always have durable storage.
public actor VolatilePersistence: SettingsPersisting {
    private var settings: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { settings[key] }
    public func saveData(_ data: Data, forKey key: String) { settings[key] = data }
}

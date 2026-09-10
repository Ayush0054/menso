import Foundation
import Security

public protocol SecureSecretDataStoring: Sendable {
    func data(service: String, account: String) async throws -> Data?
    func setData(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
}

public extension SecureSecretDataStoring {
    func string(service: String, account: String) async throws -> String? {
        guard let data = try await data(service: service, account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SecureSecretStoreError.invalidUTF8
        }
        return value
    }

    func setString(_ value: String, service: String, account: String) async throws {
        try await setData(Data(value.utf8), service: service, account: account)
    }
}

/// Generic-password Keychain storage scoped to this signed application.
/// Secrets are device-only, unavailable before first unlock, and never made synchronizable.
public actor KeychainSecretStore: SecureSecretDataStoring {
    public init() {}

    public func data(service: String, account: String) throws -> Data? {
        try Self.validate(service: service, account: account)
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let value = result as? Data else { throw SecureSecretStoreError.invalidResult }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecureSecretStoreError.keychainStatus(status)
        }
    }

    public func setData(_ data: Data, service: String, account: String) throws {
        try Self.validate(service: service, account: account)
        guard !data.isEmpty, data.count <= 64 * 1_024 else {
            throw SecureSecretStoreError.invalidSecret
        }

        let query = Self.baseQuery(service: service, account: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw SecureSecretStoreError.keychainStatus(status)
        }
    }

    public func delete(service: String, account: String) throws {
        try Self.validate(service: service, account: account)
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureSecretStoreError.keychainStatus(status)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func validate(service: String, account: String) throws {
        guard !service.isEmpty, service.utf8.count <= 256,
              !account.isEmpty, account.utf8.count <= 256
        else {
            throw SecureSecretStoreError.invalidIdentifier
        }
    }
}

public enum SecureSecretStoreError: Error, Sendable, Equatable {
    case invalidIdentifier
    case invalidSecret
    case invalidUTF8
    case invalidResult
    case randomGenerationFailed
    case keychainStatus(OSStatus)
}

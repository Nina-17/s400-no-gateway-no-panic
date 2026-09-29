import Foundation
import Security

enum ScaleCredentials {
    // Keep the Keychain namespace tied to the installed app identity.
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "org.example.s400nogateway").ble-token"
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    static func read(for id: UUID) throws -> Data? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data, data.count == 12 else {
            throw NSError(domain: "ScaleKeychain", code: Int(result))
        }
        return data
    }

    static func save(_ data: Data, for id: UUID) throws {
        guard data.count == 12 else { throw ScaleProtocolError.tokenFormat }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(query(id).merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw NSError(domain: "ScaleKeychain", code: Int(result)) }
    }

    static func remove(for id: UUID) throws {
        let result = SecItemDelete(query(id) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw NSError(domain: "ScaleKeychain", code: Int(result))
        }
    }
}

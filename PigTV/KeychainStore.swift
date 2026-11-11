import Foundation
import Security

struct KeychainStore {
    private let service = "au.markrogers.PigTV"

    private func query(for address: ServerAddress) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: address.url.absoluteString]
    }

    func token(for address: ServerAddress) throws -> String? {
        var query = query(for: address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw PigTVError.message("PigTV couldn’t read the sign-in saved on this device. Sign in again.")
        }
        return token
    }

    func save(token: String, for address: ServerAddress) throws {
        let query = query(for: address)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PigTVError.message("PigTV couldn’t save your sign-in on this device. Try again.")
        }
    }

    func remove(for address: ServerAddress) throws {
        let status = SecItemDelete(query(for: address) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PigTVError.message("PigTV couldn’t remove the sign-in saved on this device. Try again.")
        }
    }
}

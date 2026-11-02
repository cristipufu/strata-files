import Foundation
import StrataModel
import StrataSupport
import Security

/// Synchronous Security calls stay at this boundary. Independent credential stores can exercise errors and races
/// without accessing the login keychain, while production keeps the same native item format and access policy.
package nonisolated struct KeychainAccess: Sendable {
    package let copy: @Sendable (CFDictionary) -> (OSStatus, CFTypeRef?)
    package let add: @Sendable (CFDictionary) -> OSStatus
    package let update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    package let delete: @Sendable (CFDictionary) -> OSStatus

    package static let system = KeychainAccess(copy: { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result)
    }, add: { SecItemAdd($0, nil) }, update: { SecItemUpdate($0, $1) }, delete: { SecItemDelete($0) })
}

/// S3 secret keys, one generic password per server in the login keychain ("Strata S3", the server's ID). Never logged,
/// never in preferences.
package nonisolated struct RemoteKeychain: Sendable {
    package static let shared = RemoteKeychain(access: .system)
    private static let service = "Strata S3"

    private let access: KeychainAccess

    package init(access: KeychainAccess) { self.access = access }

    private func query(for server: RemoteServer) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: server.id]
    }

    package func setSecret(_ secret: String, for server: RemoteServer) -> Bool {
        let base = query(for: server)
        let changes: [String: Any] = [kSecValueData as String: Data(secret.utf8),
                                      kSecAttrLabel as String: "Strata S3: \(server.bucket ?? server.host)"]
        // Updating retains the item's native access policy and leaves its old value intact on failure.
        let updated = access.update(base as CFDictionary, changes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = base
        item.merge(changes) { _, replacement in replacement }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = access.add(item as CFDictionary)
        guard added == errSecDuplicateItem else { return added == errSecSuccess }
        // Another writer created this exact item after our lookup. Retry the update once, without deleting it.
        return access.update(base as CFDictionary, changes as CFDictionary) == errSecSuccess
    }

    package func secret(for server: RemoteServer) -> String? {
        var query = query(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = access.copy(query as CFDictionary)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    package func delete(_ server: RemoteServer) -> Bool {
        let status = access.delete(query(for: server) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

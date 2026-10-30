import Foundation
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()

    /// Service identifier used to namespace all Keychain items for this app.
    private let service = "com.loxbrige"

    private init() {}

    func save(data: Data, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Writes `data` for `key`, updating the existing item in place so there is never
    /// a moment where the item is missing (unlike `save`, which deletes then adds).
    /// Returns `true` on success.
    @discardableResult
    func update(data: Data, key: String, accessible: CFString) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    enum LoadResult {
        case found(Data)
        case notFound
        /// The item may exist but could not be read, e.g. the device is locked.
        case failed(OSStatus)
    }

    /// Like `load(key:)`, but distinguishes a missing item from a read error.
    func loadResult(key: String) -> LoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(status) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    func load(key: String) -> Data? {
        if case .found(let data) = loadResult(key: key) { return data }
        return nil
    }

    /// Removes the item for `key` from the Keychain.
    /// Returns `true` if the item was deleted or didn't exist; `false` on unexpected error.
    @discardableResult
    func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

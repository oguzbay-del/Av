import Foundation
import Security

/// Küçük gizli değerler (ör. BirdNET API anahtarı) için Keychain; UserDefaults'ta düz metin tutulmaz.
enum Keychain {
    private static let service = "com.example.avharitasi"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Eski sürümde UserDefaults'ta tutulan anahtarı bir kez taşı.
    static func migrateFromDefaults(_ key: String) {
        let d = UserDefaults.standard
        if let old = d.string(forKey: key), !old.isEmpty, get(key) == nil { set(key, old) }
        d.removeObject(forKey: key)
    }
}

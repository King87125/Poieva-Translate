import Foundation
import Security

/// Runs inside the fixed XPC service. No custom ACLs, partition changes,
/// unencrypted files, system-password handling or network operations.
public final class CredentialKeychainStore {
    public static let namespace = "studio.typebridge.mac.translation-services.v3"
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "studio.typebridge.credentials.keychain")
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func read(_ id: UUID, interactive: Bool) throws -> Data? {
        try queue.sync {
            try withInteraction(interactive) {
                let marker = "translationCredentialMigration.v3." + id.uuidString
                let value = try CredentialVersionMigration.read(wasMigrated: defaults.bool(forKey: marker),
                    readCurrent: { try self.copy(id, service: Self.namespace).map { String(decoding: $0, as: UTF8.self) } },
                    readLegacy: {
                        if let value = try self.copy(id, service: "studio.typebridge.mac.translation-services.v2") {
                            return String(decoding: value, as: UTF8.self)
                        }
                        // The original migration marker belongs to the main app.
                        // A retired v1 key must never be used after v2 was cleared.
                        let old = UserDefaults(suiteName: CredentialServiceIdentity.application)
                        guard old?.bool(forKey: "translationCredentialMigration.v2." + id.uuidString) != true else { return nil }
                        return try self.copy(id, service: "studio.typebridge.mac.translation-services").map { String(decoding: $0, as: UTF8.self) }
                    },
                    writeCurrent: { value in
                        let data = Data(value.utf8)
                        try self.update(data, id)
                        // Only finish migration after a fresh, noninteractive read.
                        guard try self.withInteraction(false, { try self.copy(id, service: Self.namespace) }) == data else {
                            throw CredentialServiceError.status(errSecAuthFailed)
                        }
                    },
                    markMigrated: { self.defaults.set(true, forKey: marker) },
                    removeLegacy: { self.retireLegacy(id) })
                return value.map { Data($0.utf8) }
            }
        }
    }

    public func write(_ value: Data?, for id: UUID) throws {
        try queue.sync {
            try withInteraction(false) {
                guard value == nil || (value!.count > 0 && value!.count <= 16_384 && String(data: value!, encoding: .utf8) != nil) else {
                    throw CredentialServiceError.status(errSecParam)
                }
                try update(value, id)
                defaults.set(true, forKey: "translationCredentialMigration.v3." + id.uuidString)
                retireLegacy(id)
            }
        }
    }

    private func query(_ id: UUID, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    private func copy(_ id: UUID, service: String) throws -> Data? {
        var q = query(id, service: service)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &raw)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let value = raw as? Data else { throw CredentialServiceError.status(status) }
        return value
    }
    private func update(_ value: Data?, _ id: UUID) throws {
        let q = query(id, service: Self.namespace)
        guard let value else {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialServiceError.status(status) }
            return
        }
        let values = [kSecValueData as String: value]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialServiceError.status(status) }
        var item = q.merging(values) { _, new in new }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialServiceError.status(added) }
    }
    private func retireLegacy(_ id: UUID) {
        try? withInteraction(false) {
            for service in ["studio.typebridge.mac.translation-services.v2", "studio.typebridge.mac.translation-services"] {
                _ = SecItemDelete(query(id, service: service) as CFDictionary)
            }
        }
    }
    private func withInteraction<T>(_ allowed: Bool, _ work: () throws -> T) throws -> T {
        var previous: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&previous)
        guard status == errSecSuccess else { throw CredentialServiceError.status(status) }
        let changed = SecKeychainSetUserInteractionAllowed(allowed)
        guard changed == errSecSuccess else { throw CredentialServiceError.status(changed) }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try work()
    }
}

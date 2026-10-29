import CryptoKit
import Foundation
import Security

public enum CredentialServiceIdentity {
    public static let application = "studio.typebridge.mac"
    public static let service = "studio.typebridge.mac.credentials"

    /// Both sides authenticate the peer's identifier AND their own signing
    /// certificate. A renamed app or unrelated self-signed binary is rejected.
    public static func requirement(for identifier: String) throws -> String {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { throw CredentialServiceError.status(errSecCSUnsigned) }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
    }
}

@objc public protocol CredentialServiceProtocol {
    func read(_ account: String, interactive: Bool, reply: @escaping (Data?, Int32) -> Void)
    func write(_ account: String, value: Data?, reply: @escaping (Int32) -> Void)
}

public enum CredentialServiceError: Error {
    case status(OSStatus)
}

/// Write before retiring a source item. A marker prevents a cleared key from
/// being resurrected from an inaccessible old copy.
public enum CredentialVersionMigration {
    public static func read(wasMigrated: Bool, readCurrent: () throws -> String?, readLegacy: () throws -> String?,
                            writeCurrent: (String) throws -> Void, markMigrated: () -> Void,
                            removeLegacy: () -> Void) throws -> String? {
        if let value = try readCurrent() { markMigrated(); return value }
        guard !wasMigrated, let value = try readLegacy() else { return nil }
        try writeCurrent(value)
        markMigrated()
        removeLegacy()
        return value
    }
}

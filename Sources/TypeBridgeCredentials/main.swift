import Foundation
import Security
import TypeBridgeCredentialSupport

final class CredentialService: NSObject, CredentialServiceProtocol {
    private let store = CredentialKeychainStore()
    func read(_ account: String, interactive: Bool, reply: @escaping (Data?, Int32) -> Void) {
        guard let id = UUID(uuidString: account) else { reply(nil, errSecParam); return }
        do { reply(try store.read(id, interactive: interactive), errSecSuccess) }
        catch CredentialServiceError.status(let status) { reply(nil, status) }
        catch { reply(nil, errSecInternalComponent) }
    }
    func write(_ account: String, value: Data?, reply: @escaping (Int32) -> Void) {
        guard let id = UUID(uuidString: account) else { reply(errSecParam); return }
        do { try store.write(value, for: id); reply(errSecSuccess) }
        catch CredentialServiceError.status(let status) { reply(status) }
        catch { reply(errSecInternalComponent) }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = CredentialService()
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: CredentialServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

do {
    let listener = NSXPCListener.service()
    let delegate = ListenerDelegate(requirement: try CredentialServiceIdentity.requirement(for: CredentialServiceIdentity.application))
    listener.delegate = delegate
    listener.resume()
    RunLoop.current.run()
} catch {
    // An unsigned service must never expose a fallback endpoint.
    exit(1)
}

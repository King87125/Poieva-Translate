import Foundation
import OSLog
import Security
import TypeBridgeCredentialSupport

/// Short synchronous calls preserve the existing store interface. Interactive
/// migration is called only by prepareForSave's background task.
enum CredentialServiceClient {
    private static let diagnostics = Logger(subsystem: "studio.typebridge.mac", category: "credentials")
    static func read(_ id: UUID, interactive: Bool) throws -> String? {
        let data = try call(interactive: interactive) { proxy, finish in
            proxy.read(id.uuidString, interactive: interactive, reply: finish)
        }
        guard let data else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw ServiceConfigurationFailure.credential }
        return value
    }
    static func write(_ value: String?, for id: UUID) throws {
        _ = try call(interactive: false) { proxy, finish in
            proxy.write(id.uuidString, value: value.map { Data($0.utf8) }) { finish(nil, $0) }
        }
    }
    private final class Reply: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var response: (Data?, OSStatus)?
        func finish(_ value: Data?, _ status: OSStatus) {
            lock.lock(); defer { lock.unlock() }
            guard response == nil else { return }
            response = (value, status); ready.signal()
        }
        var result: (Data?, OSStatus) { lock.lock(); defer { lock.unlock() }; return response ?? (nil, errSecNotAvailable) }
    }
    private static func call(interactive: Bool, send: (CredentialServiceProtocol, @escaping (Data?, Int32) -> Void) -> Void) throws -> Data? {
        let connection = NSXPCConnection(serviceName: CredentialServiceIdentity.service)
        connection.remoteObjectInterface = NSXPCInterface(with: CredentialServiceProtocol.self)
        connection.setCodeSigningRequirement(try CredentialServiceIdentity.requirement(for: CredentialServiceIdentity.service))
        let reply = Reply()
        connection.invalidationHandler = { reply.finish(nil, errSecNotAvailable) }
        connection.interruptionHandler = { reply.finish(nil, errSecNotAvailable) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(nil, errSecNotAvailable) }) as? CredentialServiceProtocol else {
            throw ServiceConfigurationFailure.credential
        }
        send(proxy) { reply.finish($0, $1) }
        let deadline: DispatchTime = interactive ? .distantFuture : .now() + .seconds(8)
        guard reply.ready.wait(timeout: deadline) == .success else { throw ServiceConfigurationFailure.credential }
        let (value, status) = reply.result
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw ServiceConfigurationFailure.credentialAuthorization
        }
        guard status == errSecSuccess else {
            diagnostics.error("Credential service failed: status=\(status, privacy: .public)")
            throw ServiceConfigurationFailure.credential
        }
        return value
    }
}

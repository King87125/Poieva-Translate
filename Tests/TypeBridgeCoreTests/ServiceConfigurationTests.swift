import Foundation
import Testing
@testable import TypeBridgeCore

@MainActor
private final class MemoryTranslationCredentials: TranslationCredentialStore {
    var values: [UUID: String] = [:]
    var reads = 0
    var failWrites = false
    func read(_ id: UUID) throws -> String? { reads += 1; return values[id] }
    func write(_ key: String?, for id: UUID) throws {
        if failWrites { throw ServiceConfigurationFailure.credential }
        values[id] = key
    }
}

struct ServiceConfigurationTests {
    private func configuration(_ url: String = "https://api.example.com/v1") -> TranslationServiceConfiguration {
        TranslationServiceConfiguration(name: "我的模型", baseURL: url, model: "custom-model")
    }
    @Test func endpointAcceptsBaseOrCompletePathWithoutDoublingIt() throws {
        #expect(try configuration(" https://api.example.com/v1/ ").validated().endpoint.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(try configuration("https://api.example.com/custom/chat/completions").validated().endpoint.absoluteString == "https://api.example.com/custom/chat/completions")
        #expect(try configuration("https://api.example.com").validated().endpoint.absoluteString == "https://api.example.com/chat/completions")
    }
    @Test func permitsLocalHTTPButRejectsRemotePlaintextAndURLSecrets() throws {
        for url in ["http://localhost:11434/v1", "http://127.0.0.1:8000/v1", "http://[::1]:8080/v1"] {
            _ = try configuration(url).validated()
        }
        for url in ["http://remote.example.com/v1", "https://user:password@example.com/v1", "https://api.example.com/v1?api_key=secret", "https://example.com/v1#secret", "example.com/v1", "file:///tmp/models"] {
            #expect(throws: ServiceConfigurationFailure.self) { try configuration(url).validated() }
        }
    }
    @Test func rejectsEmptyFieldsAndControlCharacters() {
        var c = configuration(); c.name = " \n"
        #expect(throws: ServiceConfigurationFailure.self) { try c.validated() }
        c = configuration(); c.model = "model\nother"
        #expect(throws: ServiceConfigurationFailure.self) { try c.validated() }
        c = configuration(); c.model = ""
        #expect(throws: ServiceConfigurationFailure.self) { try c.validated() }
    }
    @Test func preservesModelParametersButBlocksProtocolOverridesAndCredentials() throws {
        var c = configuration()
        c.parameters = try TranslationServiceConfiguration.parseParameters("{\"thinking\":{\"type\":\"disabled\"},\"temperature\":0}")
        #expect(try c.validated().parameters == c.parameters)
        for key in ["messages", "model", "stream", "response_format", "tools", "headers", "api_key", "Authorization"] {
            c.parameters = [key: .string("secret")]
            #expect(throws: ServiceConfigurationFailure.self) { try c.validated() }
        }
        c.parameters = ["custom": .object(["access_token": .string("secret")])]
        #expect(throws: ServiceConfigurationFailure.self) { try c.validated() }
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServiceConfiguration.parseParameters("[]") }
    }
    @Test func portablePackageRoundTripsSettingsWithoutLocalIdentity() throws {
        var c = configuration(); c.jsonMode = true; c.parameters = ["seed": .number(12)]
        let data = try TranslationServicePackage.encode([c])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(c.id.uuidString))
        let imported = try TranslationServicePackage.decode(data)
        #expect(imported.count == 1)
        #expect(imported[0].id != c.id)
        var comparable = imported[0]; comparable.id = c.id
        #expect(comparable == c)
    }
    @Test func refusesUnsupportedVersionsAdaptersAndEmbeddedKeys() throws {
        let data = try TranslationServicePackage.encode([configuration()])
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["version"] = 99
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServicePackage.decode(JSONSerialization.data(withJSONObject: root)) }
        root["version"] = 2
        var rows = try #require(root["services"] as? [[String: Any]])
        rows[0]["adapter"] = "unknown-protocol"; root["services"] = rows
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServicePackage.decode(JSONSerialization.data(withJSONObject: root)) }
        rows[0]["adapter"] = "openai-chat-completions"; rows[0]["apiKey"] = "must-not-import"
        root["services"] = rows
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServicePackage.decode(JSONSerialization.data(withJSONObject: root)) }
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServicePackage.decode(Data(repeating: 32, count: TranslationServicePackage.maximumBytes + 1)) }
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServicePackage.decode(Data("broken".utf8)) }
    }
}

@MainActor
struct ServiceStoreTests {
    private func configuration(name: String = "测试服务") -> TranslationServiceConfiguration {
        TranslationServiceConfiguration(name: name, baseURL: "https://api.example.com/v1", model: "custom-model")
    }
    private func defaults() -> (UserDefaults, String) {
        let suite = "studio.typebridge.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    @Test func freshInstallUsesAppleAndNeverReadsCredentials() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let keys = MemoryTranslationCredentials(), store = TranslationServiceStore(defaults: d, credentials: keys)
        #expect(store.selectedID == nil)
        #expect(store.activeConfiguration == nil)
        #expect(store.activeName == L10n.tr("苹果系统翻译"))
        #expect(try store.key(for: UUID()) == nil)
        #expect(keys.reads == 0)
    }
    @Test func savesAndReloadsConfigurationWithKeyOutsidePreferences() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let keys = MemoryTranslationCredentials(), store = TranslationServiceStore(defaults: d, credentials: keys)
        let c = configuration()
        try store.save(c, key: "test-only-secret-42", clearKey: false)
        #expect(store.selectedID == nil)
        try store.select(c.id)
        let reloaded = TranslationServiceStore(defaults: d, credentials: keys)
        #expect(reloaded.activeConfiguration == c)
        #expect(try reloaded.key(for: c.id) == "test-only-secret-42")
        let stored = String(decoding: try #require(d.data(forKey: "translationServices.v1")), as: UTF8.self)
        #expect(!stored.contains("test-only-secret-42"))
        let exported = String(decoding: try reloaded.exportPackage(), as: UTF8.self)
        #expect(!exported.contains("test-only-secret-42"))
        #expect(!exported.contains(c.id.uuidString))
    }
    @Test func importsAreAtomicDeduplicatedInactiveAndHaveNoCredentials() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let keys = MemoryTranslationCredentials(), store = TranslationServiceStore(defaults: d, credentials: keys)
        let existing = configuration(name: "已有服务")
        try store.save(existing, key: "existing-secret", clearKey: false); try store.select(existing.id)
        let incoming = configuration(name: "导入服务")
        let data = try TranslationServicePackage.encode([incoming, incoming])
        #expect(try store.importPackage(data) == 1)
        #expect(try store.importPackage(data) == 0)
        #expect(store.selectedID == existing.id)
        let imported = try #require(store.configurations.last)
        #expect(imported.id != incoming.id)
        #expect(!store.hasKey(imported.id))
        #expect(try store.key(for: imported.id) == nil)
        let before = store.configurations
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(root["services"] as? [[String: Any]])
        rows[1]["baseURL"] = "http://unsafe.example.com"; root["services"] = rows
        #expect(throws: ServiceConfigurationFailure.self) { try store.importPackage(JSONSerialization.data(withJSONObject: root)) }
        #expect(store.configurations == before)
        #expect(try store.key(for: existing.id) == "existing-secret")
    }
    @Test func editingHostRequiresExplicitKeyReplacementOrRemoval() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let keys = MemoryTranslationCredentials(), store = TranslationServiceStore(defaults: d, credentials: keys)
        let original = configuration()
        try store.save(original, key: "saved-secret", clearKey: false)
        var changed = original; changed.baseURL = "https://different.example.com/v1"
        #expect(throws: ServiceConfigurationFailure.self) { try store.save(changed, key: "", clearKey: false) }
        #expect(store.configurations == [original])
        #expect(keys.reads == 0)
        try store.save(changed, key: "", clearKey: true)
        #expect(store.configurations == [changed])
        #expect(!store.hasKey(original.id))
        #expect(keys.values[original.id] == nil)
    }
    @Test func deletionFallsBackToAppleAndRemovesOnlyThatServicesKey() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let keys = MemoryTranslationCredentials(), store = TranslationServiceStore(defaults: d, credentials: keys)
        let first = configuration(name: "服务一"), second = configuration(name: "服务二")
        try store.save(first, key: "first-secret", clearKey: false)
        try store.save(second, key: "second-secret", clearKey: false)
        try store.select(first.id); try store.remove(first.id)
        #expect(store.selectedID == nil)
        #expect(keys.values[first.id] == nil)
        #expect(try store.key(for: second.id) == "second-secret")
        #expect(TranslationServiceStore(defaults: d, credentials: keys).selectedID == nil)
    }
    @Test func changingProtocolOrApplicationIDCannotReuseSavedCredentialsSilently() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let keys = MemoryTranslationCredentials(), store = TranslationServiceStore(defaults: d, credentials: keys)
        let original = TranslationServiceConfiguration(name: "百度", adapter: .baidu, baseURL: TranslationServiceAdapter.baidu.defaultURL, appID: "first-app")
        try store.save(original, key: "test-secret", clearKey: false)
        var changed = original; changed.appID = "another-app"
        #expect(throws: ServiceConfigurationFailure.self) { try store.save(changed, key: "", clearKey: false) }
        changed = original; changed.adapter = .youdao
        #expect(throws: ServiceConfigurationFailure.self) { try store.save(changed, key: "", clearKey: false) }
        #expect(keys.reads == 0 && store.configurations == [original])
        try store.save(changed, key: "replacement-test-key", clearKey: false)
        #expect(store.configurations.first?.adapter == .youdao)
        #expect(try store.key(for: original.id) == "replacement-test-key")
    }
    @Test func keychainFailureDoesNotSaveOrRemoveConfiguration() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let keys = MemoryTranslationCredentials(), store = TranslationServiceStore(defaults: d, credentials: keys)
        let c = configuration()
        keys.failWrites = true
        #expect(throws: ServiceConfigurationFailure.self) { try store.save(c, key: "secret", clearKey: false) }
        #expect(store.configurations.isEmpty)
        keys.failWrites = false
        try store.save(c, key: "secret", clearKey: false); try store.select(c.id)
        keys.failWrites = true
        #expect(throws: ServiceConfigurationFailure.self) { try store.remove(c.id) }
        #expect(store.configurations == [c])
        #expect(store.selectedID == c.id)
    }
    @Test func onlyChangesToTheActiveServiceNotifyTheTranslator() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let store = TranslationServiceStore(defaults: d, credentials: MemoryTranslationCredentials())
        var c = configuration(); var changes = 0
        store.onActiveServiceChange = { changes += 1 }
        try store.save(c, key: "", clearKey: false)
        #expect(changes == 0)
        try store.select(c.id); #expect(changes == 1)
        c.model = "another-model"; try store.save(c, key: "", clearKey: false)
        #expect(changes == 2)
        _ = try store.importPackage(TranslationServicePackage.encode([configuration(name: "另一个")]))
        #expect(changes == 2)
        try store.remove(c.id); #expect(changes == 3)
    }
    @Test func commitGuardAndCorruptStoragePreserveExistingState() throws {
        let (d, suite) = defaults(); defer { d.removePersistentDomain(forName: suite) }
        let store = TranslationServiceStore(defaults: d, credentials: MemoryTranslationCredentials())
        let c = configuration()
        try store.save(c, key: "", clearKey: false)
        store.canModify = { false }
        #expect(throws: ServiceConfigurationFailure.self) { try store.select(c.id) }
        #expect(throws: ServiceConfigurationFailure.self) { try store.remove(c.id) }
        #expect(store.configurations == [c])
        let corrupt = Data("invalid preferences".utf8)
        d.set(corrupt, forKey: "translationServices.v1")
        let reloaded = TranslationServiceStore(defaults: d, credentials: MemoryTranslationCredentials())
        #expect(reloaded.selectedID == nil)
        #expect(!reloaded.issue.isEmpty)
        #expect(d.data(forKey: "translationServices.v1") == corrupt)
    }
}

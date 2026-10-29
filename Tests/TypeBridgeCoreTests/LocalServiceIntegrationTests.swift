import Foundation
import Testing
@testable import TypeBridgeCore

@MainActor
private final class IntegrationCredentials: TranslationCredentialStore {
    func read(_ id: UUID) throws -> String? { nil }
    func write(_ key: String?, for id: UUID) throws {}
}

/// Opt-in, loopback-only check against the development fixture. Never contacts a cloud service.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TYPEBRIDGE_TEST_SERVER_URL"] != nil))
@MainActor
struct LocalServiceIntegrationTests {
    @Test func contextAndPreferencesReachBothTranslationPathsOverRealHTTP() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["TYPEBRIDGE_TEST_SERVER_URL"])
        guard var origin = URLComponents(string: endpoint), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(origin.host ?? "") else {
            Issue.record("HTTP fixture must use loopback"); return
        }
        let suite = "studio.typebridge.assistance-integration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranslationPreferenceStore(defaults: defaults)
        try preferences.save(.init(preferences: .init(tone: .concise, instructions: "Short sentences.",
            terms: [.init(source: "译入", translation: "TypeBridge", target: .english)])))
        let reloaded = TranslationPreferenceStore(defaults: defaults)
        let guidance = TranslationGuidance(context: .init(before: "Welcome to TypeBridge.", after: "Next sentence."), preferences: reloaded.settings.preferences)
        let request = TranslationRequest(text: "# 你好，译入 12\n\n`file.swift`", source: .simplifiedChinese, target: .english, guidance: guidance)
        let helperConfiguration = TranslationServiceConfiguration(name: "本机辅助样例", baseURL: endpoint, model: "local-test-assistant", jsonMode: true)
        origin.path = "/deepl/v2/translate"
        let base = try ProfessionalTranslationProvider(configuration: .init(name: "本机初译样例", adapter: .deepL, baseURL: #require(origin.url?.absoluteString)), credential: { "local-test-secret" })
        var helperCalls = 0
        let assisted = AssistedTranslationProvider(base: base, makeAssistant: {
            helperCalls += 1
            return try CompatibleTranslationAssistant(configuration: helperConfiguration)
        })
        let expected = "# Hello, TypeBridge 12\n\n`file.swift`"
        #expect(try await assisted.translate(request) == expected)
        #expect(helperCalls == 1)
        var directConfiguration = helperConfiguration; directConfiguration.model = "local-test-guided"
        let direct = AssistedTranslationProvider(base: try CompatibleTranslationProvider(configuration: directConfiguration), makeAssistant: {
            Issue.record("Direct AI translation must not call a second model"); return nil
        })
        #expect(try await direct.translate(request) == expected)
    }
    @Test func importedHTTPTemplateUsesAllFourEnginesAndRejectsRedirects() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["TYPEBRIDGE_TEST_SERVER_URL"])
        guard var origin = URLComponents(string: base), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(origin.host ?? "") else {
            Issue.record("HTTP fixture must use loopback"); return
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: project.appendingPathComponent("Examples/lingdong-http.json"))
        let suite = "studio.typebridge.http-integration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationServiceStore(defaults: defaults, credentials: IntegrationCredentials())
        #expect(try store.importPackage(data) == 1 && store.selectedID == nil)
        var configuration = try #require(store.configurations.first)
        #expect(!store.hasKey(configuration.id))
        origin.path = "/translation/language/translate"
        configuration.baseURL = try #require(origin.url?.absoluteString)
        for engine in ["1", "2", "3", "4"] {
            configuration.parameters["engine"] = .string(engine)
            try store.save(configuration, key: "", clearKey: false)
            let imported = try #require(TranslationServicePackage.decode(store.exportPackage()).first)
            let provider = try TranslationServiceFactory.make(configuration: imported, credential: { "local-test-secret" })
            #expect(try await provider.translate(.init(text: "# Hello.\n\n- Hello.", source: .english, target: .simplifiedChinese)) == "# 你好。\n\n- 你好。")
        }
        origin.path = "/http-redirect"; configuration.baseURL = try #require(origin.url?.absoluteString)
        let redirected = try TranslationServiceFactory.make(configuration: configuration, credential: { "local-test-secret" })
        do { _ = try await redirected.translate(.init(text: "Hello.", source: .english, target: .simplifiedChinese)); Issue.record("Redirect must fail") }
        catch { #expect(error.localizedDescription.contains("302")) }
        #expect(!String(decoding: try store.exportPackage(), as: UTF8.self).contains("local-test-secret"))
    }
    @Test func professionalProtocolsUseTheRealTransportAndIndependentSignatureVerifier() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["TYPEBRIDGE_TEST_SERVER_URL"])
        let host = URLComponents(string: base)?.host
        #expect(["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? ""))
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? ""), var origin = URLComponents(string: base) else { return }
        for (adapter, path) in [(TranslationServiceAdapter.deepL, "/deepl/v2/translate"), (.baidu, "/baidu"), (.youdao, "/youdao")] {
            origin.path = path
            let configuration = TranslationServiceConfiguration(name: "本机样例", adapter: adapter, baseURL: try #require(origin.url?.absoluteString), appID: adapter.needsAppID ? "local-test-app" : "")
            let decoded = try TranslationServicePackage.decode(TranslationServicePackage.encode([configuration]))
            let provider = try TranslationServiceFactory.make(configuration: #require(decoded.first), credential: { "local-test-secret" })
            let result = try await provider.translate(TranslationRequest(text: "# Hello.\n\n- Hello.", source: .english, target: .simplifiedChinese))
            #expect(result == "# 你好。\n\n- 你好。")
        }
    }
    @Test func exportedConfigurationCanBeImportedSelectedAndUsedByTheRealTransport() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["TYPEBRIDGE_TEST_SERVER_URL"])
        let host = URLComponents(string: url)?.host
        #expect(["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? ""))
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? "") else { return }
        let source = TranslationServiceConfiguration(name: "Loopback fixture", baseURL: url, model: "local-test-model")
        let data = try TranslationServicePackage.encode([source])
        let suite = "studio.typebridge.integration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationServiceStore(defaults: defaults, credentials: IntegrationCredentials())
        #expect(try store.importPackage(data) == 1)
        #expect(store.selectedID == nil)
        let imported = try #require(store.configurations.first)
        try store.select(imported.id)
        let provider = try CompatibleTranslationProvider(configuration: #require(store.activeConfiguration))
        let translated = try await provider.translate(TranslationRequest(text: "你好", source: .simplifiedChinese, target: .english))
        #expect(translated == "Hello")
        try store.remove(imported.id)
        #expect(store.selectedID == nil)
        #expect(store.activeName == L10n.tr("苹果系统翻译"))
    }
}

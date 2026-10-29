import Foundation
import Testing
@testable import TypeBridgeCore

private func lingdongFixture() throws -> TranslationServiceConfiguration {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try #require(TranslationServicePackage.decode(Data(contentsOf: root.appendingPathComponent("Examples/lingdong-http.json"))).first)
}

private final class TemplateHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var json: ServiceJSONValue; var delay: TimeInterval = 0 }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?
    private static var received: [URLRequest] = []
    private let stateLock = NSLock()
    private var stopped = false
    static func configure(_ block: @escaping (URLRequest) throws -> Reply) {
        lock.lock(); defer { lock.unlock() }; handler = block; received = []
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return received }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            recorded.httpBody = data
        }
        Self.lock.lock(); Self.received.append(recorded); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let reply = try handler(recorded), data = try JSONEncoder().encode(reply.json)
            let deliver: @Sendable () -> Void = { [self] in
                stateLock.lock(); let stopped = self.stopped; stateLock.unlock()
                guard !stopped, let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            }
            if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) } else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

struct HTTPTemplateConfigurationTests {
    @Test func shippedTemplateImportsAndPreservesEngineLanguageMappings() throws {
        let configuration = try lingdongFixture(), template = try #require(configuration.http)
        #expect(configuration.adapter == .customHTTP && configuration.model.isEmpty)
        #expect(configuration.endpoint.absoluteString == "https://ldfy.cc/translation/language/translate")
        let option = try #require(template.options.first)
        #expect(option.defaultValue == "2" && option.choices.map(\.title) == ["DeepL", "Google", "百度", "有道"])
        for (engine, from, to) in [("1", "ZH", "JA"), ("2", "zh-cn", "ja"), ("3", "zh", "jp"), ("4", "zh-CHS", "ja")] {
            let body = try template.render(text: "你好", source: .simplifiedChinese, target: .japanese, parameters: ["engine": .string(engine)])
            #expect(HTTPTranslationTemplate.field("sourceLang", in: body) == .string(from))
            #expect(HTTPTranslationTemplate.field("targetLang", in: body) == .string(to))
            #expect(HTTPTranslationTemplate.field("type", in: body) == .string(engine))
        }
        let traditional = try template.render(text: "您好", source: .traditionalChinese, target: .english, parameters: ["engine": .string("1")])
        #expect(HTTPTranslationTemplate.field("sourceLang", in: traditional) == .string("ZH"))
        #expect(throws: HTTPTranslationFailure.self) { try template.render(text: "Hello", source: .english, target: .traditionalChinese, parameters: ["engine": .string("1")]) }
    }
    @Test func placeholdersEscapeAsJSONAndNeverReinterpretInsertedText() throws {
        var template = HTTPTranslationTemplate()
        template.request = ["input": .object(["text": .string("{{text}}")]), "language": .string("to={{target}}"), "notes": .array([.string("{{source}}")])]
        let original = #"a\"},\"stolen\":true,\"text\":\"{{target}}\n🧑🏽‍💻"#
        let rendered = try template.render(text: original, source: .english, target: .simplifiedChinese, parameters: [:])
        let data = try JSONEncoder().encode(rendered)
        let decoded = try JSONDecoder().decode(ServiceJSONValue.self, from: data)
        #expect(HTTPTranslationTemplate.field("input.text", in: decoded) == .string(original))
        #expect(HTTPTranslationTemplate.field("language", in: decoded) == .string("to=zh-Hans"))
        #expect(HTTPTranslationTemplate.field("notes.0", in: decoded) == .string("en"))
        #expect(HTTPTranslationTemplate.field("stolen", in: decoded) == nil)
    }
    @Test func versionThreeRoundTripAndOlderPackagesRemainCompatible() throws {
        var configuration = try lingdongFixture(); configuration.parameters["engine"] = .string("3")
        let data = try TranslationServicePackage.encode([configuration])
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["version"] as? Int == 3)
        let decoded = try #require(TranslationServicePackage.decode(data).first)
        #expect(decoded.id != configuration.id && decoded.http == configuration.http && decoded.parameters == configuration.parameters)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let old = try TranslationServicePackage.decode(Data(contentsOf: project.appendingPathComponent("Examples/professional-services.json")))
        #expect(old.count == 3 && old.allSatisfy { $0.http == nil })
        var wrongVersion = root; wrongVersion["version"] = 2
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServicePackage.decode(JSONSerialization.data(withJSONObject: wrongVersion)) }
    }
    @Test func unknownFieldsAndEmbeddedCredentialsAreRejectedAtEveryTemplateLevel() throws {
        let configuration = try lingdongFixture(), template = try #require(configuration.http)
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        for field in ["apiKey", "headers", "script", "unexpected"] {
            var changed = original; changed[field] = "never-import-this"
            #expect(throws: Error.self) { try HTTPTranslationTemplate.parse(String(decoding: JSONSerialization.data(withJSONObject: changed), as: UTF8.self)) }
        }
        var nested = original
        var options = try #require(nested["options"] as? [[String: Any]])
        options[0]["apiKey"] = "never-import-this"; nested["options"] = options
        #expect(throws: Error.self) { try JSONDecoder().decode(HTTPTranslationTemplate.self, from: JSONSerialization.data(withJSONObject: nested)) }
        options = try #require(original["options"] as? [[String: Any]])
        var choices = try #require(options[0]["choices"] as? [[String: Any]])
        choices[0]["secret"] = "never-import-this"; options[0]["choices"] = choices; nested["options"] = options
        #expect(throws: Error.self) { try JSONDecoder().decode(HTTPTranslationTemplate.self, from: JSONSerialization.data(withJSONObject: nested)) }
        var body = template; body.request["api_key"] = .string("never-import-this")
        #expect(throws: ServiceConfigurationFailure.self) { try body.validate(parameters: [:]) }
    }
    @Test func invalidPlaceholdersMappingsHeadersAndPathsCannotBeSaved() throws {
        let initial = HTTPTranslationTemplate()
        let invalidRequests: [[String: ServiceJSONValue]] = [
            ["text": .string("{{text}}")], ["text": .string("{{text}}"), "to": .string("{{target}}"), "key": .string("{{key}}")],
            ["text": .string("{{text}}"), "to": .string("{{target}}"), "extra": .string("{{unfinished")],
            ["{{field}}": .string("{{text}}"), "to": .string("{{target}}")]]
        for request in invalidRequests { var value = initial; value.request = request; #expect(throws: ServiceConfigurationFailure.self) { try value.validate(parameters: [:]) } }
        for header in ["Host", "Cookie", "Content-Length", "Content-Type", "X-Key\r\nInjected", "Proxy-Authorization", "Sec-Key"] {
            var value = initial; value.keyHeader = header
            #expect(throws: ServiceConfigurationFailure.self) { try value.validate(parameters: [:]) }
        }
        for path in ["", ".data", "data..text", "$.data", "data[0].text", "data.text()"] {
            var value = initial; value.responsePath = path
            #expect(throws: ServiceConfigurationFailure.self) { try value.validate(parameters: [:]) }
        }
        var value = initial; value.languageCodes = ["unknown": "en"]
        #expect(throws: ServiceConfigurationFailure.self) { try value.validate(parameters: [:]) }
        value = initial; value.method = "GET"
        #expect(throws: ServiceConfigurationFailure.self) { try value.validate(parameters: [:]) }
        value = initial; value.keyPrefix = "Bearer\n"
        #expect(throws: ServiceConfigurationFailure.self) { try value.validate(parameters: [:]) }
    }
    @Test func parameterValuesMustBelongToDeclaredOptionsAndNullStatusRoundTrips() throws {
        let template = try #require(lingdongFixture().http)
        for values: [String: ServiceJSONValue] in [["engine": .string("99")], ["engine": .number(2)], ["other": .string("2")]] {
            #expect(throws: ServiceConfigurationFailure.self) { try template.validate(parameters: values) }
        }
        var nullStatus = template; nullStatus.successValue = .null
        #expect(try HTTPTranslationTemplate.parse(nullStatus.jsonText).successValue == .null)
        var duplicate = template; duplicate.options.append(duplicate.options[0])
        #expect(throws: ServiceConfigurationFailure.self) { try duplicate.validate(parameters: [:]) }
    }
}

@MainActor
private final class HTTPMemoryCredentials: TranslationCredentialStore {
    var values: [UUID: String] = [:]
    var reads = 0
    func read(_ id: UUID) throws -> String? { reads += 1; return values[id] }
    func write(_ key: String?, for id: UUID) throws { values[id] = key }
}

@Suite(.serialized)
@MainActor
struct HTTPTranslationProviderTests {
    private func network() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TemplateHTTPStub.self]
        return URLSession(configuration: configuration)
    }
    private func reply(_ text: String = "你好") -> ServiceJSONValue { .object(["code": .number(200), "data": .object(["translatedText": .string(text)])]) }
    private func request() -> TranslationRequest { .init(text: "Hello", source: .english, target: .simplifiedChinese) }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(1)) }; return condition()
    }
    @Test func factoryUsesSelectedEngineAndBearerWithoutOpenAIFields() async throws {
        TemplateHTTPStub.configure { incoming in
            #expect(incoming.httpMethod == "POST" && incoming.url?.path == "/translation/language/translate")
            #expect(incoming.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
            let body = try JSONDecoder().decode(ServiceJSONValue.self, from: #require(incoming.httpBody))
            #expect(HTTPTranslationTemplate.field("text", in: body) == .string("Hello"))
            #expect(HTTPTranslationTemplate.field("sourceLang", in: body) == .string("en"))
            #expect(HTTPTranslationTemplate.field("targetLang", in: body) == .string("zh"))
            #expect(HTTPTranslationTemplate.field("type", in: body) == .string("3"))
            #expect(HTTPTranslationTemplate.field("model", in: body) == nil && HTTPTranslationTemplate.field("messages", in: body) == nil)
            return .init(json: .object(["code": .number(200), "data": .object(["translatedText": .string("你好")])]))
        }
        var configuration = try lingdongFixture(); configuration.parameters["engine"] = .string("3")
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try TranslationServiceFactory.make(configuration: configuration, session: session, credential: { "fixture-secret" })
        #expect(try await provider.translate(request()) == "你好")
        #expect(TemplateHTTPStub.requests.count == 1)
    }
    @Test func customHeaderAndNoAuthenticationUseOnlyTheConfiguredCredentialChannel() async throws {
        var configuration = try lingdongFixture()
        configuration.http?.authentication = .header; configuration.http?.keyHeader = "X-Translation-Key"; configuration.http?.keyPrefix = "Token "
        TemplateHTTPStub.configure { incoming in
            #expect(incoming.value(forHTTPHeaderField: "X-Translation-Key") == "Token fixture-secret")
            #expect(incoming.value(forHTTPHeaderField: "Authorization") == nil)
            return .init(json: .object(["code": .number(200), "data": .object(["translatedText": .string("你好")])]))
        }
        let session = network(); defer { session.invalidateAndCancel() }
        var reads = 0
        let first = try HTTPTranslationProvider(configuration: configuration, session: session, credential: { reads += 1; return "fixture-secret" })
        #expect(try await first.translate(request()) == "你好" && reads == 1)
        configuration.http?.authentication = .none
        TemplateHTTPStub.configure { incoming in
            #expect(incoming.value(forHTTPHeaderField: "X-Translation-Key") == nil && incoming.value(forHTTPHeaderField: "Authorization") == nil)
            return .init(json: .object(["code": .number(200), "data": .object(["translatedText": .string("你好")])]))
        }
        let second = try HTTPTranslationProvider(configuration: configuration, session: session, credential: { reads += 1; return "must-not-read" })
        #expect(try await second.translate(request()) == "你好" && reads == 1)
    }
    @Test func missingKeyUnsupportedLanguageAndLocalNoOpsNeverSendRequests() async throws {
        TemplateHTTPStub.configure { _ in Issue.record("Unexpected request"); return .init(json: .null) }
        let session = network(); defer { session.invalidateAndCancel() }
        var reads = 0
        var configuration = try lingdongFixture()
        let provider = try HTTPTranslationProvider(configuration: configuration, session: session, credential: { reads += 1; return nil })
        await #expect(throws: ProfessionalTranslationFailure.self) { try await provider.translate(request()) }
        #expect(reads == 1 && TemplateHTTPStub.requests.isEmpty)
        configuration.parameters["engine"] = .string("1")
        let deepL = try HTTPTranslationProvider(configuration: configuration, session: session, credential: { reads += 1; return "fixture-secret" })
        await #expect(throws: HTTPTranslationFailure.self) { try await deepL.translate(.init(text: "Hello", source: .english, target: .traditionalChinese)) }
        #expect(reads == 1)
        #expect(try await provider.translate(.init(text: "Hello", source: .english, target: .english)) == "Hello")
        #expect(try await provider.translate(.init(text: "請建立專案", source: .traditionalChinese, target: .simplifiedChinese)) == "请建立专案")
        #expect(try await provider.translate(.init(text: "`let count = 1`", source: .english, target: .simplifiedChinese)) == "`let count = 1`")
        #expect(reads == 1 && TemplateHTTPStub.requests.isEmpty)
    }
    @Test func boundedFragmentsKeepMarkdownWhitespaceUnicodeAndRealProgress() async throws {
        TemplateHTTPStub.configure { incoming in
            let body = try JSONDecoder().decode(ServiceJSONValue.self, from: #require(incoming.httpBody))
            guard case let .string(text) = HTTPTranslationTemplate.field("text", in: body) else { throw HTTPTranslationFailure.invalidResponse }
            #expect(text.utf16.count <= 16)
            return .init(json: .object(["code": .number(200), "data": .object(["translatedText": .string(text)])]))
        }
        var configuration = try lingdongFixture(); configuration.http?.maxCharacters = 16
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try HTTPTranslationProvider(configuration: configuration, session: session, credential: { "fixture-secret" })
        let original = "#   Hello there 🧑🏽‍💻 please preserve spaces\r\n\r\n- Thanks  friend\n`code` https://example.com"
        var progress: [TranslationProgress] = []
        #expect(try await provider.translate(.init(text: original, source: .english, target: .simplifiedChinese), progress: { progress.append($0) }) == original)
        #expect(TemplateHTTPStub.requests.count > 2)
        #expect(progress.first?.completedCharacters == 0 && progress.last?.completedCharacters == progress.last?.totalCharacters)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.completedCharacters <= $1.completedCharacters })
    }
    @Test func responsePathsCanReadArraysWithoutExecutingExpressions() async throws {
        var configuration = try lingdongFixture(); configuration.http?.responsePath = "data.0.text"; configuration.http?.successPath = ""
        TemplateHTTPStub.configure { _ in .init(json: .object(["data": .array([.object(["text": .string("你好")])])])) }
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try HTTPTranslationProvider(configuration: configuration, session: session, credential: { "fixture-secret" })
        #expect(try await provider.translate(request()) == "你好")
    }
    @Test func businessAndHTTPFailuresUseSafeMessagesWithoutReflectingServerBodies() async throws {
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try HTTPTranslationProvider(configuration: lingdongFixture(), session: session, credential: { "fixture-secret" })
        for (status, code, expected) in [(200, 401, "密钥"), (200, 402, "额度"), (200, 429, "频繁"), (402, 402, "额度"), (200, 999, "成功状态")] {
            TemplateHTTPStub.configure { _ in .init(status: status, json: .object(["code": .number(Double(code)), "msg": .string("DO-NOT-REFLECT-fixture-secret")])) }
            do { _ = try await provider.translate(request()); Issue.record("Expected failure") }
            catch { #expect(error.localizedDescription.contains(expected)); #expect(!error.localizedDescription.contains("DO-NOT-REFLECT") && !error.localizedDescription.contains("fixture-secret")) }
            #expect(TemplateHTTPStub.requests.count == 1)
        }
    }
    @Test func missingWrongEmptyAndMultilineFieldsNeverReturnAPartialResult() async throws {
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try HTTPTranslationProvider(configuration: lingdongFixture(), session: session, credential: { "fixture-secret" })
        for value: ServiceJSONValue in [.string(""), .string(" \t"), .string("first\nsecond"), .array([.string("你好")]), .number(200)] {
            TemplateHTTPStub.configure { _ in .init(json: .object(["code": .number(200), "data": .object(["translatedText": value])])) }
            await #expect(throws: HTTPTranslationFailure.self) { try await provider.translate(request()) }
        }
        TemplateHTTPStub.configure { _ in .init(json: .object(["data": .object(["translatedText": .string("你好")])])) }
        await #expect(throws: HTTPTranslationFailure.self) { try await provider.translate(request()) }
        var count = 0
        TemplateHTTPStub.configure { _ in
            count += 1
            return .init(json: count == 1 ? .object(["code": .number(200), "data": .object(["translatedText": .string("你好")])]) : .object(["code": .number(402)]))
        }
        await #expect(throws: HTTPTranslationFailure.self) { try await provider.translateSegments(["Hello", "World"], for: request()) }
        #expect(count == 2)
    }
    @Test func cancellationStopsLaterFragmentsAndCannotPublishCompletedProgress() async throws {
        TemplateHTTPStub.configure { _ in .init(json: .object(["code": .number(200), "data": .object(["translatedText": .string("你好")])]), delay: 0.15) }
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try HTTPTranslationProvider(configuration: lingdongFixture(), session: session, credential: { "fixture-secret" })
        var progress: [TranslationProgress] = []
        let task = Task { try await provider.translateSegments(["Hello", "World"], for: request(), progress: { progress.append($0) }) }
        #expect(await eventually { TemplateHTTPStub.requests.count == 1 })
        provider.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(TemplateHTTPStub.requests.count == 1 && progress.allSatisfy { $0.completedCharacters == 0 })
    }
    @Test func importExportNeverStoresKeysAndChangingAuthenticationNeedsExplicitReplacement() throws {
        let suite = "studio.typebridge.http-tests.\(UUID().uuidString)", keys = HTTPMemoryCredentials()
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationServiceStore(defaults: defaults, credentials: keys)
        var configuration = try lingdongFixture()
        try store.save(configuration, key: "fixture-secret", clearKey: false)
        configuration.parameters["engine"] = .string("1")
        try store.save(configuration, key: "", clearKey: false)
        #expect(try store.key(for: configuration.id) == "fixture-secret")
        let exported = try store.exportPackage()
        #expect(!String(decoding: exported, as: UTF8.self).contains("fixture-secret"))
        #expect(try store.importPackage(exported) == 0)
        let reloaded = TranslationServiceStore(defaults: defaults, credentials: keys)
        #expect(reloaded.configurations.first?.http == configuration.http)
        configuration.http?.authentication = .header
        #expect(throws: ServiceConfigurationFailure.self) { try store.save(configuration, key: "", clearKey: false) }
        try store.save(configuration, key: "replacement-fixture", clearKey: false)
        #expect(try store.key(for: configuration.id) == "replacement-fixture")
        #expect(!String(decoding: try #require(defaults.data(forKey: "translationServices.v1")), as: UTF8.self).contains("fixture-secret"))
    }
}

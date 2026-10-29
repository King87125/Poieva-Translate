import Foundation
import Testing
@testable import TypeBridgeCore

private final class ProfessionalHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var json: [String: Any]; var delay: TimeInterval = 0 }
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
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = data
        }
        Self.lock.lock(); Self.received.append(recorded); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let reply = try handler(recorded), data = try JSONSerialization.data(withJSONObject: reply.json)
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

struct ProfessionalConfigurationTests {
    private func config(_ adapter: TranslationServiceAdapter) -> TranslationServiceConfiguration {
        .init(name: adapter.name, adapter: adapter, baseURL: adapter.defaultURL, appID: adapter.needsAppID ? "test-app" : "")
    }
    @Test func typesValidateOnlyTheirOwnFieldsAndHaveUsableDefaultEndpoints() throws {
        for adapter in [TranslationServiceAdapter.deepL, .baidu, .youdao] {
            let value = try config(adapter).validated()
            #expect(value.model.isEmpty)
            #expect(value.endpoint.absoluteString == adapter.defaultURL)
            var invalid = value; invalid.model = "wrong-model"
            #expect(throws: ServiceConfigurationFailure.self) { try invalid.validated() }
            if adapter.needsAppID {
                invalid = value; invalid.appID = ""
                #expect(throws: ServiceConfigurationFailure.self) { try invalid.validated() }
            }
        }
        var deepL = config(.deepL); deepL.baseURL = "https://api-free.deepl.com"
        #expect(try deepL.validated().endpoint.absoluteString == "https://api-free.deepl.com/v2/translate")
    }
    @Test func professionalOptionsRejectUnrelatedFieldsAndCredentials() throws {
        for adapter in [TranslationServiceAdapter.deepL, .baidu, .youdao] {
            var invalid = config(adapter); invalid.parameters = ["api_key": .string("never-export")]
            #expect(throws: ServiceConfigurationFailure.self) { try invalid.validated() }
            invalid.parameters = ["text": .string("override")]
            #expect(throws: ServiceConfigurationFailure.self) { try invalid.validated() }
        }
        var deepL = config(.deepL); deepL.parameters = ["formality": .string("prefer_more"), "model_type": .string("quality_optimized")]
        _ = try deepL.validated()
        var youdao = config(.youdao); youdao.parameters = ["domain": .string("medicine"), "vocabId": .string("my-glossary")]
        _ = try youdao.validated()
        youdao.parameters["domain"] = .string("unsupported")
        #expect(throws: ServiceConfigurationFailure.self) { try youdao.validated() }
    }
    @Test func versionTwoPackagesRoundTripAllTypesAndVersionOneStillImports() throws {
        let list = [.deepL, .baidu, .youdao].map(config)
        let package = try TranslationServicePackage.encode(list)
        let decoded = try TranslationServicePackage.decode(package)
        #expect(decoded.map(\.adapter) == list.map(\.adapter))
        #expect(decoded.map(\.appID) == list.map(\.appID))
        #expect(decoded.allSatisfy { row in !list.contains { $0.id == row.id } })
        let old = Data(#"{"format":"typebridge.translation-services","version":1,"services":[{"name":"旧服务","adapter":"openai-chat-completions","baseURL":"https://api.example.com/v1","model":"old-model","jsonMode":false,"parameters":{}}]}"#.utf8)
        let restored = try TranslationServicePackage.decode(old)
        #expect(restored.first?.model == "old-model")
        #expect(restored.first?.appID == "")
        var root = try #require(JSONSerialization.jsonObject(with: package) as? [String: Any])
        var entries = try #require(root["services"] as? [[String: Any]])
        entries[0]["secretKey"] = "must-not-import"; root["services"] = entries
        #expect(throws: ServiceConfigurationFailure.self) { try TranslationServicePackage.decode(JSONSerialization.data(withJSONObject: root)) }
    }
    @Test func legacyLocalConfigurationDecodesWithoutLosingIdentity() throws {
        let original = TranslationServiceConfiguration(name: "Old", baseURL: "https://api.example.com/v1", model: "model")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "appID")
        let loaded = try JSONDecoder().decode(TranslationServiceConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded == original)
    }
    @Test func baiduOfficialSigningExampleAndFormEncoding() {
        #expect(TranslationServiceSigning.baidu(appID: "2015063000000001", query: "apple", salt: "1435660288", key: "12345678") == "f89f9594663708c1605f3d736d01d2d4")
        let data = TranslationServiceSigning.form(["q": "中文 &+\nemoji😀"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("%26%2B%0A"))
        #expect(URLComponents(string: "https://example.com?" + text)?.queryItems?.first?.value == "中文 &+\nemoji😀")
    }
    @Test func youdaoSigningUsesUnencodedUnicodeCodePointsAndLongInputRule() {
        let samples = [("Hello.", "5a698ac9d02d6e071b9dc4d598f7dcb72757b49a13ce2a9e62fb395ca0a68e3c"),
                       ("0123456789abcdefghijklmno", "c728cb230b0f31fd1ca1d90a2a5d195794bd5523e9323213e884ad3c4a2f6374"),
                       ("你好😀e\u{301}世界abcdefghijklmno👩‍💻", "67c009931ebe0d8598e93e0723411774d51be4f216d93a03be3cd83506af77b2")]
        for (query, expected) in samples {
            #expect(TranslationServiceSigning.youdao(appID: "test-app", query: query, salt: "test-salt", timestamp: "1700000000", key: "test-secret") == expected)
        }
    }
    @Test func chunkPlanKeepsWhitespaceUnicodeAndWholeParagraphStructure() throws {
        let original = String(repeating: " ", count: 6_000) + String(repeating: "你好😀。", count: 2_000) + "\t "
        let plan = try ProfessionalTranslationPlan(texts: [original, "  ", "Next"], adapter: .baidu)
        #expect(plan.fragments.allSatisfy { $0.text.utf8.count <= 5_800 })
        #expect(plan.fragments.allSatisfy { $0.text.utf16.count <= 1_000 })
        #expect(try plan.assemble(plan.fragments.map(\.text), target: .simplifiedChinese) == [original, "  ", "Next"])
        let youdao = try ProfessionalTranslationPlan(texts: [String(repeating: "😀", count: 5_000)], adapter: .youdao)
        #expect(youdao.fragments.allSatisfy { $0.text.utf16.count <= 4_800 })
        #expect(try youdao.assemble(youdao.fragments.map(\.text), target: .simplifiedChinese).first == String(repeating: "😀", count: 5_000))
    }
}

@Suite(.serialized)
@MainActor
struct ProfessionalProviderTests {
    private func configuration(_ adapter: TranslationServiceAdapter) -> TranslationServiceConfiguration {
        .init(name: "测试-" + adapter.name, adapter: adapter, baseURL: adapter.defaultURL, appID: adapter.needsAppID ? "test-app" : "")
    }
    private func network() -> URLSession {
        let options = URLSessionConfiguration.ephemeral; options.protocolClasses = [ProfessionalHTTPStub.self]
        return URLSession(configuration: options)
    }
    private var request: TranslationRequest { .init(text: "Hello", source: .english, target: .simplifiedChinese) }
    private func fields(_ request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        return Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://example.com?" + String(decoding: data, as: UTF8.self))?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(2)) }; return condition()
    }

    @Test func deepLBatchesFiftyTextsAndUsesDedicatedAuthorizationAndLanguageCodes() async throws {
        ProfessionalHTTPStub.configure { request in
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let texts = try #require(body["text"] as? [String])
            #expect(texts.count <= 50)
            #expect(body["source_lang"] as? String == "EN")
            #expect(body["target_lang"] as? String == "ZH-HANT")
            #expect(body["preserve_formatting"] as? Bool == true)
            #expect(body["formality"] as? String == "prefer_more")
            #expect(body["model"] == nil && body["messages"] == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key test-secret")
            return .init(json: ["translations": texts.map { ["text": "譯文 " + $0] }])
        }
        let session = network(); defer { session.invalidateAndCancel() }
        var config = configuration(.deepL); config.parameters = ["formality": .string("prefer_more")]
        let provider = try TranslationServiceFactory.make(configuration: config, session: session, credential: { "test-secret" })
        var progress: [TranslationProgress] = []
        let texts = (0..<61).map { "Hello \($0)" }
        let result = try await provider.translateSegments(texts, for: .init(text: "Hello", source: .english, target: .traditionalChinese), progress: { progress.append($0) })
        #expect(result == texts.map { "譯文 " + $0 })
        #expect(ProfessionalHTTPStub.requests.count == 2)
        #expect(progress.count == 3 && progress.last?.completedCharacters == progress.last?.totalCharacters)
    }
    @Test func baiduSignsTheRawBatchAndPreservesMarkdownCodeAndURLs() async throws {
        ProfessionalHTTPStub.configure { [self] request in
            let body = try fields(request), query = try #require(body["q"]), salt = try #require(body["salt"])
            #expect(body["appid"] == "test-app" && body["from"] == "en" && body["to"] == "zh")
            #expect(body["sign"] == TranslationServiceSigning.baidu(appID: "test-app", query: query, salt: salt, key: "test-secret"))
            #expect(!query.contains("private.swift") && !query.contains("example.com/private"))
            #expect(request.url?.query == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
            return .init(json: ["trans_result": query.components(separatedBy: "\n").map { ["src": $0, "dst": "译文"] }])
        }
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try TranslationServiceFactory.make(configuration: configuration(.baidu), session: session, credential: { "test-secret" })
        let result = try await provider.translate(.init(text: "# Hello\n\n- Read `private.swift` and https://example.com/private", source: .english, target: .simplifiedChinese))
        #expect(result == "# 译文\n\n- 译文 `private.swift` 译文 https://example.com/private")
        #expect(ProfessionalHTTPStub.requests.count == 1)
    }
    @Test func youdaoUsesV3FormStrictDirectionAndOptionalDomain() async throws {
        ProfessionalHTTPStub.configure { [self] request in
            let body = try fields(request), query = try #require(body["q"])
            #expect(body["appKey"] == "test-app" && body["from"] == "en" && body["to"] == "zh-CHS")
            #expect(body["signType"] == "v3" && body["strict"] == "true" && body["domain"] == "computers")
            let salt = try #require(body["salt"]), timestamp = try #require(body["curtime"])
            #expect(body["sign"] == TranslationServiceSigning.youdao(appID: "test-app", query: query, salt: salt, timestamp: timestamp, key: "test-secret"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return .init(json: ["errorCode": "0", "query": query, "translation": ["译文"]])
        }
        let session = network(); defer { session.invalidateAndCancel() }
        var config = configuration(.youdao); config.parameters = ["domain": .string("computers")]
        let provider = try TranslationServiceFactory.make(configuration: config, session: session, credential: { "test-secret" })
        #expect(try await provider.translateSegments(["Hello &+😀", "Another sentence"], for: request) == ["译文", "译文"])
        #expect(ProfessionalHTTPStub.requests.count == 2)
    }
    @Test func malformedEmptyExtraNewlineAndMismatchedSourceResultsAreRefused() async throws {
        let session = network(); defer { session.invalidateAndCancel() }
        let cases: [(TranslationServiceAdapter, [String: Any])] = [
            (.deepL, ["translations": []]), (.deepL, ["translations": [["text": "一"], ["text": "二"]]]),
            (.deepL, ["translations": [["text": "一\n二"]]]), (.deepL, ["translations": [["text": ""]]]),
            (.baidu, ["trans_result": [["src": "Changed", "dst": "译文"]]]),
            (.youdao, ["errorCode": "0", "query": "Changed", "translation": ["译文"]]),
            (.youdao, ["errorCode": "0", "translation": ["一", "二"]])]
        for (adapter, response) in cases {
            ProfessionalHTTPStub.configure { _ in .init(json: response) }
            let provider = try TranslationServiceFactory.make(configuration: configuration(adapter), session: session, credential: { "test-secret" })
            var completed = false
            do { _ = try await provider.translate(request); completed = true } catch {}
            #expect(!completed)
        }
    }
    @Test func businessErrorsAreHelpfulWithoutReflectingServerMessagesOrKeys() async throws {
        let session = network(); defer { session.invalidateAndCancel() }
        let cases: [(TranslationServiceAdapter, ProfessionalHTTPStub.Reply, String)] = [
            (.deepL, .init(status: 456, json: ["message": "echo test-secret"]), "额度"),
            (.baidu, .init(json: ["error_code": "54001", "error_msg": "echo test-secret"]), "密钥"),
            (.youdao, .init(json: ["errorCode": "401", "errorMessage": "echo test-secret"]), "余额")]
        for (adapter, response, expected) in cases {
            ProfessionalHTTPStub.configure { _ in response }
            let provider = try TranslationServiceFactory.make(configuration: configuration(adapter), session: session, credential: { "test-secret" })
            do { _ = try await provider.translate(request); Issue.record("Must reject service error") }
            catch { #expect(error.localizedDescription.contains(expected)); #expect(!error.localizedDescription.contains("test-secret")) }
        }
    }
    @Test func missingCredentialsAndLocalNoOpsNeverMakeNetworkCalls() async throws {
        let session = network(); defer { session.invalidateAndCancel() }
        for adapter in [TranslationServiceAdapter.deepL, .baidu, .youdao] {
            ProfessionalHTTPStub.configure { _ in .init(json: [:]) }
            var reads = 0
            let provider = try TranslationServiceFactory.make(configuration: configuration(adapter), session: session, credential: { reads += 1; return nil })
            #expect(try await provider.translate(.init(text: "Hello", source: .english, target: .english)) == "Hello")
            _ = try await provider.translate(.init(text: "`private.swift`", source: .english, target: .simplifiedChinese))
            #expect(try await provider.translate(.init(text: "請建立專案", source: .traditionalChinese, target: .simplifiedChinese)) == "请建立专案")
            #expect(reads == 0)
            do { _ = try await provider.translate(request); Issue.record("Missing key must fail") } catch { #expect(error is ProfessionalTranslationFailure) }
            #expect(ProfessionalHTTPStub.requests.isEmpty)
        }
    }
    @Test func cancellingARequestRejectsLateResultsAndCompletedProgress() async throws {
        ProfessionalHTTPStub.configure { _ in .init(json: ["translations": [["text": "你好"]]], delay: 1) }
        let session = network(); defer { session.invalidateAndCancel() }
        let provider = try TranslationServiceFactory.make(configuration: configuration(.deepL), session: session, credential: { "test-secret" })
        var progress: [TranslationProgress] = []
        let task = Task { @MainActor in try await provider.translate(request, progress: { progress.append($0) }) }
        #expect(await eventually { !ProfessionalHTTPStub.requests.isEmpty })
        provider.cancel()
        do { _ = try await task.value; Issue.record("Cancelled operation must fail") } catch { #expect(error is CancellationError) }
        #expect(progress.allSatisfy { $0.completedCharacters == 0 })
    }
    @Test func baiduBatchesRespectFreeTierCharactersBytesAndOneRequestPerSecond() async throws {
        let session = network(); defer { session.invalidateAndCancel() }
        var dates: [Date] = []
        ProfessionalHTTPStub.configure { [self] request in
            dates.append(Date())
            let query = try #require(fields(request)["q"])
            #expect(query.utf8.count <= 5_800)
            #expect(query.utf16.count <= 1_000)
            return .init(json: ["trans_result": query.components(separatedBy: "\n").map { ["src": $0, "dst": "译文"] }])
        }
        let provider = try TranslationServiceFactory.make(configuration: configuration(.baidu), session: session, credential: { "test-secret" })
        _ = try await provider.translateSegments([String(repeating: "中", count: 600), String(repeating: "b", count: 600)], for: request)
        #expect(dates.count == 2 && dates[1].timeIntervalSince(dates[0]) >= 1)
    }
    @Test func cancellingDuringBaiduThrottlePreventsTheNextPaidRequest() async throws {
        let session = network(); defer { session.invalidateAndCancel() }
        ProfessionalHTTPStub.configure { [self] request in
            let query = try #require(fields(request)["q"])
            return .init(json: ["trans_result": [["src": query, "dst": "译文"]]])
        }
        let provider = try TranslationServiceFactory.make(configuration: configuration(.baidu), session: session, credential: { "test-secret" })
        var hasProgress = false
        let task = Task { @MainActor in try await provider.translateSegments([String(repeating: "a", count: 600), String(repeating: "b", count: 600)], for: request, progress: { if $0.completedCharacters > 0 { hasProgress = true } }) }
        #expect(await eventually { hasProgress })
        provider.cancel()
        do { _ = try await task.value; Issue.record("Cancelled throttle must fail") } catch { #expect(error is CancellationError) }
        #expect(ProfessionalHTTPStub.requests.count == 1)
    }
}

import Foundation
import Testing
@testable import TypeBridgeCore

private final class TranslationHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var data: Data; var delay: TimeInterval = 0 }
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
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close(); recorded.httpBody = data
        }
        Self.lock.lock(); Self.received.append(recorded); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let reply = try handler(recorded)
            let deliver: @Sendable () -> Void = { [self] in
                stateLock.lock(); let stopped = self.stopped; stateLock.unlock()
                guard !stopped, let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) }
            else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

@Suite(.serialized)
@MainActor
struct CompatibleProviderTests {
    private func configuration(jsonMode: Bool = false) -> TranslationServiceConfiguration {
        TranslationServiceConfiguration(name: "用户自选服务", baseURL: "https://translation.example.com/v1", model: "user-model-id", jsonMode: jsonMode)
    }
    private func session() -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [TranslationHTTPStub.self]
        return URLSession(configuration: settings)
    }
    private var request: TranslationRequest { TranslationRequest(text: "Hello", source: .english, target: .simplifiedChinese) }
    private func response(_ translations: [[String: String]], finish: String = "stop") throws -> Data {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)
        return try envelope(content, finish: finish)
    }
    private func envelope(_ content: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test func usesUserConfigurationAndBatchesSegmentsInOneRequest() async throws {
        let body = try response([["id": "1", "text": "第二"], ["id": "0", "text": "第一"]])
        TranslationHTTPStub.configure { _ in .init(data: body) }
        let network = session(); defer { network.invalidateAndCancel() }
        var configuration = configuration(jsonMode: true)
        configuration.parameters = ["thinking": .object(["type": .string("disabled")])]
        let provider = try CompatibleTranslationProvider(configuration: configuration, session: network, credential: { "test-only-secret" })
        var progress: [TranslationProgress] = []
        let result = try await provider.translateSegments(["First", "Second"], for: request, progress: { progress.append($0) })
        #expect(result == ["第一", "第二"])
        #expect(TranslationHTTPStub.requests.count == 1)
        let sent = try #require(TranslationHTTPStub.requests.first)
        #expect(sent.url?.path == "/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-secret")
        let sentBody = try #require(sent.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(json["model"] as? String == "user-model-id")
        #expect(json["stream"] as? Bool == false)
        #expect(json["store"] as? Bool == false)
        #expect((json["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((json["response_format"] as? [String: String])?["type"] == "json_object")
        #expect(progress.first?.completedCharacters == 0)
        #expect(progress.last == TranslationProgress(completedCharacters: 11, totalCharacters: 11))
    }
    @Test func explicitPersonConstraintIsSentAndWrongPerspectiveCannotCompleteTranslation() async throws {
        let invalid = try response([["id": "0", "text": "He went to the ward."]])
        TranslationHTTPStub.configure { _ in .init(data: invalid) }
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network)
        var completed = false
        await #expect(throws: TranslationAssistanceFailure.self) {
            try await provider.translate(.init(text: "我还是去了病房。", source: .simplifiedChinese, target: .english), progress: { progress in
                if progress.completedCharacters == progress.totalCharacters { completed = true }
            })
        }
        let body = try #require(TranslationHTTPStub.requests.first?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: String]])
        let content = try #require(messages.last?["content"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        #expect((payload["segments"] as? [[String: String]])?.first?["sourcePersonConstraint"] == "first_person_singular")
        #expect(!completed && TranslationHTTPStub.requests.count == 1)
    }

    @Test func sendsOnlyProseAndRestoresProtectedCodeAndURLsLocally() async throws {
        let body = try response([["id": "0", "text": "请编辑"], ["id": "1", "text": "并阅读"]])
        TranslationHTTPStub.configure { _ in .init(data: body) }
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network)
        let source = "Please edit `secret-file.swift` and read https://example.com/private"
        let translated = try await provider.translate(TranslationRequest(text: source, source: .english, target: .simplifiedChinese))
        #expect(translated == "请编辑 `secret-file.swift` 并阅读 https://example.com/private")
        let sent = try #require(TranslationHTTPStub.requests.first)
        let raw = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        #expect(!raw.contains("secret-file.swift"))
        #expect(!raw.contains("example.com/private"))
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func preservesParagraphAndListStructureWithOneBatch() async throws {
        let body = try response([["id": "0", "text": "你好"], ["id": "1", "text": "谢谢"]])
        TranslationHTTPStub.configure { _ in .init(data: body) }
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network)
        let text = try await provider.translate(TranslationRequest(text: "# Hello\n\n- Thanks", source: .english, target: .simplifiedChinese))
        #expect(text == "# 你好\n\n- 谢谢")
        #expect(TranslationHTTPStub.requests.count == 1)
    }

    @Test func malformedDuplicateMissingEmptyAndFencedResultsAreRejected() async throws {
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network)
        let invalid = [
            try response([["id": "0", "text": "一"], ["id": "0", "text": "二"]]),
            try response([["id": "0", "text": "一"]]),
            try response([["id": "0", "text": "一"], ["id": "2", "text": "二"]]),
            try response([["id": "0", "text": ""], ["id": "1", "text": "二"]]),
            try response([["id": "0", "text": "一\n额外内容"], ["id": "1", "text": "二"]]),
            try envelope("```json\n{\"translations\":[]}\n```"),
            try envelope("Here is an explanation"),
            Data("not a response".utf8)
        ]
        for data in invalid {
            TranslationHTTPStub.configure { _ in .init(data: data) }
            var completed = false
            do { _ = try await provider.translateSegments(["One", "Two"], for: request); completed = true } catch {}
            #expect(!completed)
        }
    }

    @Test func detectsTruncationAndSanitizesHTTPFailures() async throws {
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network)
        let truncated = try response([["id": "0", "text": "你好"]], finish: "length")
        TranslationHTTPStub.configure { _ in .init(data: truncated) }
        do { _ = try await provider.translate(request); Issue.record("Truncated output must fail") }
        catch { #expect(error.localizedDescription == RemoteTranslationFailure.truncated.localizedDescription) }
        TranslationHTTPStub.configure { _ in .init(status: 401, data: Data("echoed test-only-secret".utf8)) }
        do { _ = try await provider.translate(request); Issue.record("Unauthorized output must fail") }
        catch {
            #expect(error.localizedDescription == RemoteTranslationFailure.status(401).localizedDescription)
            #expect(!error.localizedDescription.contains("test-only-secret"))
        }
    }

    @Test func cancellationStopsNetworkAndNeverReportsCompletedProgress() async throws {
        let body = try response([["id": "0", "text": "你好"]])
        TranslationHTTPStub.configure { _ in .init(data: body, delay: 1) }
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network)
        var progress: [TranslationProgress] = []
        let task = Task { @MainActor in try await provider.translate(request, progress: { progress.append($0) }) }
        #expect(await eventually { !TranslationHTTPStub.requests.isEmpty })
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request must fail") }
        catch { #expect(error is CancellationError) }
        #expect(progress.allSatisfy { $0.completedCharacters == 0 })
    }

    @Test func emptyProtectedOnlyAndSameLanguageNeverReadKeysOrCallNetwork() async throws {
        TranslationHTTPStub.configure { _ in .init(data: Data()) }
        let network = session(); defer { network.invalidateAndCancel() }
        var keyReads = 0
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network, credential: { keyReads += 1; return "secret" })
        let same = try await provider.translate(TranslationRequest(text: "Hello", source: .english, target: .english))
        #expect(same == "Hello")
        _ = try await provider.translateSegments([], for: request)
        _ = try await provider.translate(TranslationRequest(text: "`file.swift`", source: .english, target: .simplifiedChinese))
        #expect(keyReads == 0)
        #expect(TranslationHTTPStub.requests.isEmpty)
    }

    @Test func contextualTranslationSendsOnlyBoundedReferenceAndRelevantPreferences() async throws {
        TranslationHTTPStub.configure { _ in .init(data: try self.response([["id": "0", "text": "Hello, TypeBridge"]])) }
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration(), session: network)
        let guidance = TranslationGuidance(context: .init(before: String(repeating: "x", count: 900), after: "After"),
            preferences: .init(tone: .concise, instructions: "Short sentences", target: .english,
                terms: [.init(source: "译入", translation: "TypeBridge"), .init(source: "irrelevant", translation: "Do not send")]))
        let translated = try await provider.translate(.init(text: "你好，译入", source: .simplifiedChinese, target: .english, guidance: guidance))
        #expect(translated == "Hello, TypeBridge" && TranslationHTTPStub.requests.count == 1)
        let sent = try #require(TranslationHTTPStub.requests.first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        let payload = try #require(JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: Any])
        let reference = try #require(payload["reference"] as? [String: Any])
        #expect((reference["before"] as? String)?.count == 600)
        #expect(reference["style"] as? String == "concise")
        #expect((reference["terminology"] as? [[String: String]]) == [["source": "译入", "translation": "TypeBridge"]])
        #expect(messages[0]["content"]!.contains("Never translate or reproduce reference text"))
    }

    @Test func compatibleAssistantUsesOneStructuredRequestAndExistingCredentials() async throws {
        TranslationHTTPStub.configure { _ in .init(data: try self.response([["id": "0", "text": "Hello, TypeBridge 12"]])) }
        let network = session(); defer { network.invalidateAndCancel() }
        let helper = try CompatibleTranslationAssistant(configuration: configuration(jsonMode: true), session: network, credential: { "test-only-secret" })
        let request = TranslationRefinementRequest(originals: ["你好，译入 12"], drafts: ["Hello, Yiru 12"], source: .simplifiedChinese,
            target: .english, guidance: .init(preferences: .init(terms: [.init(source: "译入", translation: "TypeBridge")])))
        #expect(try await helper.refine(request) == ["Hello, TypeBridge 12"])
        #expect(TranslationHTTPStub.requests.count == 1)
        let sent = try #require(TranslationHTTPStub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-secret")
        let json = try #require(JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        #expect(json["store"] as? Bool == false && json["stream"] as? Bool == false)
        #expect((json["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == TranslationRefinementRequest.instructions)
        #expect(!messages[1]["content"]!.contains("test-only-secret"))
    }

    @Test func compatibleAssistantRejectsMalformedTruncatedAndSecretEchoedErrors() async throws {
        let network = session(); defer { network.invalidateAndCancel() }
        let helper = try CompatibleTranslationAssistant(configuration: configuration(), session: network)
        let request = TranslationRefinementRequest(originals: ["Hello"], drafts: ["你好"], source: .english,
            target: .simplifiedChinese, guidance: .init())
        for data in [try envelope("not json"), try envelope("{}", finish: "length"), try response([["id": "9", "text": "你好"]])] {
            TranslationHTTPStub.configure { _ in .init(data: data) }
            await #expect(throws: (any Error).self) { try await helper.refine(request) }
        }
        TranslationHTTPStub.configure { _ in .init(status: 500, data: Data("secret-echo".utf8)) }
        do { _ = try await helper.refine(request); Issue.record("Must fail") }
        catch { #expect(!error.localizedDescription.contains("secret-echo")) }
    }

    @Test func cancellingAssistantStopsTheNetworkAndDropsLateResult() async throws {
        TranslationHTTPStub.configure { _ in .init(data: try self.response([["id": "0", "text": "你好"]]), delay: 1) }
        let network = session(); defer { network.invalidateAndCancel() }
        let helper = try CompatibleTranslationAssistant(configuration: configuration(), session: network)
        let request = TranslationRefinementRequest(originals: ["Hello"], drafts: ["你好"], source: .english,
            target: .simplifiedChinese, guidance: .init())
        let task = Task { try await helper.refine(request) }
        #expect(await eventually { !TranslationHTTPStub.requests.isEmpty })
        helper.cancel()
        do { _ = try await task.value; Issue.record("Must cancel") }
        catch { #expect(error is CancellationError) }
    }

    @Test func importedOpenRouterTemplateWorksForTranslationAndAssistanceWithoutReasoningReplay() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: project.appendingPathComponent("Examples/openrouter-nemotron-free.json"))
        let configuration = try #require(TranslationServicePackage.decode(data).first)
        #expect(configuration.isRemoteModelAPI && !configuration.jsonMode)
        #expect(configuration.model == "nvidia/nemotron-3-ultra-550b-a55b:free")
        #expect(configuration.endpoint.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        let content = #"{"translations":[{"id":"0","text":"你好"}]}"#
        let reply = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": [
            "content": content, "reasoning_details": [["type": "reasoning.text", "text": "unused-provider-metadata"]]
        ]]]])
        TranslationHTTPStub.configure { _ in .init(data: reply) }
        let network = session(); defer { network.invalidateAndCancel() }
        let provider = try CompatibleTranslationProvider(configuration: configuration, session: network, credential: { "test-only-openrouter-key" })
        #expect(try await provider.translate(.init(text: "Hello", source: .english, target: .simplifiedChinese)) == "你好")
        let helper = try CompatibleTranslationAssistant(configuration: configuration, session: network, credential: { "test-only-openrouter-key" })
        #expect(try await helper.refine(.init(originals: ["Hello"], drafts: ["您好"], source: .english, target: .simplifiedChinese,
            guidance: .init(preferences: .init(tone: .natural)))) == ["你好"])
        #expect(TranslationHTTPStub.requests.count == 2)
        for sent in TranslationHTTPStub.requests {
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-openrouter-key")
            let body = try #require(sent.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect((object["reasoning"] as? [String: Bool])?["enabled"] == false)
            #expect(object["max_tokens"] as? Int == 4096)
            #expect(object["response_format"] == nil)
            #expect(object["models"] == nil)
            #expect((object["messages"] as? [[String: String]])?.count == 2)
            #expect(!String(decoding: body, as: UTF8.self).contains("unused-provider-metadata"))
        }
        #expect(!String(decoding: try TranslationServicePackage.encode([configuration]), as: UTF8.self).contains("test-only-openrouter-key"))
    }
}

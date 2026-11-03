import Foundation
import Testing
@testable import TypeBridgeCore

@MainActor private final class CaptionTestCredentials: TranslationCredentialStore {
    var keys: [UUID: String] = [:]
    var reads = 0
    func read(_ id: UUID) throws -> String? { reads += 1; return keys[id] }
    func write(_ key: String?, for id: UUID) throws { keys[id] = key }
}

struct CaptionConfigurationTests {
    @Test func canonicalizesOnlySecureOrLoopbackEndpointsWithoutURLCredentials() throws {
        let valid = try SpeechServiceConfiguration(name: "Mine", baseURL: "https://speech.example.test/v1/", model: "my-transcriber").validated()
        #expect(valid.endpoint.absoluteString == "wss://speech.example.test/v1/realtime?intent=transcription")
        #expect(try SpeechServiceConfiguration(name: "Mine", baseURL: "ws://127.0.0.1:19084/v1/realtime?intent=transcription", model: "test").validated().baseURL == "ws://127.0.0.1:19084/v1/realtime")
        for url in ["http://speech.example.test/v1", "ws://speech.example.test/v1", "wss://key@host.test/realtime", "wss://host.test/realtime?key=secret", "wss://host.test/realtime#key", "file:///tmp/audio"] {
            #expect(throws: CaptionFailure.self) { try SpeechServiceConfiguration(name: "Mine", baseURL: url, model: "test").validated() }
        }
    }
    @Test @MainActor func keyIsNeverSavedInPreferencesAndCannotFollowAnOriginChange() async throws {
        let suite = "Poieva.SpeechTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CaptionTestCredentials(), store = SpeechServiceStore(defaults: defaults, credentials: credentials)
        var configuration = SpeechServiceConfiguration(name: "Mine", baseURL: "https://speech.example.test/v1", model: "test")
        try store.save(configuration, key: "fixture-only-speech-key", clear: false)
        #expect(credentials.reads == 0)
        let data = try #require(defaults.data(forKey: "speechServices.v1"))
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-only-speech-key"))
        let reloaded = SpeechServiceStore(defaults: defaults, credentials: credentials)
        #expect(reloaded.hasKey(configuration.id))
        #expect(try reloaded.key(for: configuration.id) == "fixture-only-speech-key")
        configuration.baseURL = "https://elsewhere.example.test/v1"
        #expect(throws: ServiceConfigurationFailure.self) { try reloaded.keyForTest(configuration, key: "", clear: false) }
        #expect(throws: ServiceConfigurationFailure.self) { try reloaded.save(configuration, key: "", clear: false) }
        #expect(reloaded.configurations.first?.baseURL.contains("elsewhere") == false)
        try reloaded.save(configuration, key: "", clear: true)
        #expect(!reloaded.hasKey(configuration.id) && credentials.keys[configuration.id] == nil)
    }
    @Test func eventParsingKeepsItemIdentityAndNeverReflectsServerMessages() throws {
        let delta = Data(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"one","delta":"Hello"}"#.utf8)
        #expect(try RealtimeTranscriptionProtocol.event(delta) == .delta(id: "one", text: "Hello"))
        let committed = Data(#"{"type":"input_audio_buffer.committed","item_id":"two","previous_item_id":"one"}"#.utf8)
        #expect(try RealtimeTranscriptionProtocol.event(committed) == .committed(id: "two", previous: "one"))
        for body in [#"{"type":"error","error":{"code":"invalid_api_key","message":"PRIVATE-ECHO"}}"#,
                     #"{"type":"conversation.item.input_audio_transcription.failed","error":{"message":"PRIVATE-ECHO"}}"#] {
            do { _ = try RealtimeTranscriptionProtocol.event(Data(body.utf8)); Issue.record("Must fail") }
            catch { #expect(!error.localizedDescription.contains("PRIVATE-ECHO")) }
        }
        for body in ["{}", "not JSON", #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"one","delta":3}"#] {
            #expect(throws: CaptionFailure.self) { try RealtimeTranscriptionProtocol.event(Data(body.utf8)) }
        }
        #expect(throws: CaptionFailure.self) { try RealtimeTranscriptionProtocol.event(Data(repeating: 65, count: 65_537)) }
    }
    @Test func sessionIsTranscriptionOnlyWithExplicitPCMAndNoConversationTools() throws {
        let data = Data(try RealtimeTranscriptionProtocol.configuration(model: "my-model").utf8)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["type"] as? String == "session.update")
        let session = try #require(root["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription" && session["tools"] == nil)
        let audio = try #require(session["audio"] as? [String: Any]), input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["rate"] as? Int == 24_000 && format["type"] as? String == "audio/pcm")
        #expect(input["turn_detection"] is NSNull)
    }
}

struct CaptionAudioTests {
    private func frame(_ value: Int16 = 4000) throws -> CaptionAudioFrame {
        var samples = [Int16](repeating: value.littleEndian, count: 4800)
        return try CaptionAudioFrame(pcm: samples.withUnsafeMutableBytes { Data($0) })
    }
    @Test func silenceIsBoundedAndSpeechKeepsItsPreRollWithoutDuplicatePackets() throws {
        var gate = CaptionAudioGate()
        let quiet = try frame(0), voice = try frame()
        for _ in 0..<100 { #expect(gate.consume(quiet).isEmpty) }
        let start = gate.consume(voice)
        #expect(start == [.append(quiet.pcm), .append(quiet.pcm), .append(voice.pcm)])
        #expect(gate.consume(quiet) == [.append(quiet.pcm)])
        #expect(gate.consume(quiet) == [.append(quiet.pcm)])
        #expect(gate.consume(quiet) == [.append(quiet.pcm), .commit])
        #expect(gate.consume(quiet).isEmpty)
    }
    @Test func continuousSpeechCommitsAtABoundedIntervalAndBadPCMIsRejected() throws {
        var gate = CaptionAudioGate(), commits = 0
        let voice = try frame()
        for _ in 0..<81 { commits += gate.consume(voice).filter { $0 == .commit }.count }
        #expect(commits == 2)
        #expect(abs(voice.duration - 0.2) < 0.001 && voice.level > 0)
        for bytes in [Data(), Data([1]), Data(repeating: 0, count: 19_202)] {
            #expect(throws: CaptionFailure.self) { try CaptionAudioFrame(pcm: bytes) }
        }
    }
}

@MainActor private final class CaptionPendingTranslator: TranslationProvider {
    let name = "Caption fixture"
    var requests: [TranslationRequest] = []
    var pending: [Int: CheckedContinuation<String, Error>] = [:]
    func translate(_ request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> String {
        let index = requests.count; requests.append(request)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func translateSegments(_ texts: [String], for request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> [String] { [] }
    func cancel() {}
    func complete(_ index: Int, _ text: String) { pending.removeValue(forKey: index)?.resume(returning: text) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CaptionFailure.authentication) }
    func clean() { for index in Array(pending.keys) { complete(index, "Cleanup") } }
}

@MainActor struct CaptionPipelineTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(1)) }
        return condition()
    }
    private func start(_ controller: CaptionTranslationController, _ provider: CaptionPendingTranslator) {
        controller.start(provider: provider) { text, before in
            TranslationRequest(text: text, source: .english, target: .simplifiedChinese, guidance: .init(context: .init(before: before)))
        }
    }
    @Test func partialsNeverTriggerTranslationAndDuplicateFinalsDoNotBillAgain() async throws {
        let controller = CaptionTranslationController(), provider = CaptionPendingTranslator()
        defer { controller.stop(); provider.clean() }
        start(controller, provider)
        try controller.receive(.delta(id: "one", text: "Hello"))
        #expect(provider.requests.isEmpty)
        try controller.receive(.completed(id: "one", text: "Hello."))
        try controller.receive(.completed(id: "one", text: "Hello."))
        #expect(await eventually { provider.requests.count == 1 })
        provider.complete(0, "你好。")
        #expect(await eventually { controller.lines.first?.translation == "你好。" })
        #expect(provider.requests.count == 1 && controller.lines.count == 1)
    }
    @Test func lateCompletionsStayWithTheirItemAndContextsDoNotIncludeFutureTurns() async throws {
        let controller = CaptionTranslationController(), provider = CaptionPendingTranslator()
        defer { controller.stop(); provider.clean() }
        start(controller, provider)
        try controller.receive(.committed(id: "one", previous: nil))
        try controller.receive(.committed(id: "two", previous: "one"))
        try controller.receive(.completed(id: "two", text: "Second sentence."))
        #expect(await eventually { provider.requests.count == 1 })
        try controller.receive(.completed(id: "one", text: "First sentence."))
        provider.complete(0, "第二句。")
        #expect(await eventually { provider.requests.count == 2 })
        provider.complete(1, "第一句。")
        #expect(await eventually { controller.lines.allSatisfy { !$0.translation.isEmpty } })
        #expect(controller.lines.map(\.id) == ["one", "two"])
        #expect(controller.lines.map(\.translation) == ["第一句。", "第二句。"])
        #expect(provider.requests[1].guidance?.context.before == "")
    }
    @Test func stoppingRejectsALateTranslationFromThePreviousSession() async throws {
        let controller = CaptionTranslationController(), old = CaptionPendingTranslator(), next = CaptionPendingTranslator()
        defer { controller.stop(); old.clean(); next.clean() }
        start(controller, old); try controller.receive(.completed(id: "old", text: "Old sentence."))
        #expect(await eventually { old.requests.count == 1 })
        controller.stop(); start(controller, next)
        try controller.receive(.completed(id: "new", text: "New sentence."))
        #expect(await eventually { next.requests.count == 1 })
        old.complete(0, "过期结果。")
        next.complete(0, "新结果。")
        #expect(await eventually { controller.lines.first?.translation == "新结果。" })
        #expect(controller.lines.map(\.id) == ["new"])
    }
    @Test func aCommitCanCorrectOrderEvenAfterAFinalTranscriptArrives() async throws {
        let controller = CaptionTranslationController(), provider = CaptionPendingTranslator()
        defer { controller.stop(); provider.clean() }
        start(controller, provider)
        try controller.receive(.delta(id: "two", text: "Second"))
        try controller.receive(.delta(id: "one", text: "First"))
        try controller.receive(.completed(id: "two", text: "Second sentence."))
        try controller.receive(.committed(id: "two", previous: "one"))
        #expect(controller.lines.map(\.id) == ["one", "two"])
        #expect(controller.lines[1].source == "Second sentence.")
    }
    @Test func aSlowTranslatorCannotCreateAnUnboundedQueue() async throws {
        let controller = CaptionTranslationController(), provider = CaptionPendingTranslator()
        defer { controller.stop(); provider.clean() }
        start(controller, provider)
        try controller.receive(.completed(id: "0", text: "First."))
        #expect(await eventually { provider.requests.count == 1 })
        for index in 1...8 { try controller.receive(.completed(id: "\(index)", text: "Sentence.")) }
        #expect(throws: CaptionFailure.self) { try controller.receive(.completed(id: "overflow", text: "Too late.")) }
        #expect(provider.requests.count == 1)
    }
    @Test func translationFailureStopsTheQueueAndRetainsTheSourceWithoutRetrying() async throws {
        let controller = CaptionTranslationController(), provider = CaptionPendingTranslator()
        defer { controller.stop(); provider.clean() }
        var failures = 0; controller.onFailure = { _ in failures += 1 }
        start(controller, provider)
        try controller.receive(.completed(id: "first", text: "Keep the source."))
        try controller.receive(.completed(id: "second", text: "Do not bill this."))
        #expect(await eventually { provider.requests.count == 1 })
        provider.fail(0)
        #expect(await eventually { failures == 1 })
        #expect(provider.requests.count == 1 && controller.lines[0].source == "Keep the source.")
        #expect(!controller.error.isEmpty && controller.lines[0].translation.isEmpty)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["POIEVA_TEST_SPEECH_URL"] != nil))
@MainActor struct CaptionSocketIntegrationTests {
    private func configuration(_ model: String = "fixture-valid", path: String = "/v1/realtime") throws -> SpeechServiceConfiguration {
        let endpoint = try #require(ProcessInfo.processInfo.environment["POIEVA_TEST_SPEECH_URL"])
        var url = try #require(URLComponents(string: endpoint))
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") else { throw CaptionFailure.configuration }
        url.path = path; url.query = nil
        return try SpeechServiceConfiguration(name: "Public fixture", baseURL: #require(url.url?.absoluteString), model: model).validated()
    }
    @Test func realWebSocketReceivesIncrementalAndFinalTranscripts() async throws {
        let socket = RealtimeTranscriber(); defer { socket.cancel() }
        try await socket.connect(configuration: configuration("fixture-auth"), key: "fixture-only-key")
        let reader = Task { @MainActor in
            var values: [CaptionTranscriptEvent] = []
            for try await value in socket.events {
                values.append(value)
                if case .completed = value { return values }
            }
            return values
        }
        try await socket.send(.append(Data(repeating: 2, count: 9600)))
        try await socket.send(.commit)
        let values = try await reader.value
        #expect(values.contains(.delta(id: "one", text: "Hello,")))
        #expect(values.last == .completed(id: "one", text: "Hello, how are you?"))
    }
    @Test func cancellationDuringHandshakeNeverStartsAReadySession() async throws {
        let socket = RealtimeTranscriber(), configuration = try configuration("fixture-wait")
        let connecting = Task { try await socket.connect(configuration: configuration, key: nil) }
        try await Task.sleep(for: .milliseconds(40)); socket.cancel()
        do { try await connecting.value; Issue.record("Cancelled handshake became ready") }
        catch { #expect(error is CancellationError) }
    }
    @Test func rejectsAuthenticationAndRedirectsInsteadOfForwardingTheKey() async throws {
        for path in ["/forbidden", "/redirect"] {
            let socket = RealtimeTranscriber(); defer { socket.cancel() }
            await #expect(throws: Error.self) { try await socket.connect(configuration: configuration(path: path), key: "fixture-only-key") }
        }
        let incompatible = RealtimeTranscriber(); defer { incompatible.cancel() }
        await #expect(throws: CaptionFailure.self) { try await incompatible.connect(configuration: configuration("fixture-wrong-session"), key: nil) }
        var statisticsURL = URLComponents(url: try configuration().endpoint, resolvingAgainstBaseURL: false)!
        statisticsURL.scheme = "http"; statisticsURL.path = "/fixture-stats"; statisticsURL.query = nil
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: #require(statisticsURL.url))
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(value["redirect_sink_hits"] == 0)
    }
}

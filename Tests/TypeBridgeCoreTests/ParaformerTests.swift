import Foundation
import Testing
@testable import TypeBridgeCore

struct ParaformerProtocolTests {
    @Test func endpointHasNoRealtimeQueryAndRejectsCredentialsAndOtherModelFamilies() throws {
        let value = try SpeechServiceConfiguration(name: "Mine", baseURL: SpeechServiceKind.alibabaParaformer.defaultBaseURL,
            model: "paraformer-realtime-v2", kind: .alibabaParaformer).validated()
        #expect(value.endpoint.absoluteString == "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
        for (url, model) in [(value.baseURL + "?key=PRIVATE", value.model), (value.baseURL + "?model=paraformer-realtime-v2", value.model),
                             (value.baseURL, "sambert-zhide-v1"), (value.baseURL, "paraformer-v2"), (value.baseURL, "qwen-audio-3.1-asr-flash-streaming")] {
            #expect(throws: CaptionFailure.self) { try SpeechServiceConfiguration(name: "Mine", baseURL: url, model: model, kind: .alibabaParaformer).validated() }
        }
    }
    @Test func taskControlsAreSpeechOnlyAndMustCorrelateToTheRequestedTask() throws {
        let id = UUID().uuidString
        let body = try #require(JSONSerialization.jsonObject(with: Data(ParaformerTranscriptionProtocol.start(model: "paraformer-realtime-v2", taskID: id).utf8)) as? [String: Any])
        let header = try #require(body["header"] as? [String: String]), payload = try #require(body["payload"] as? [String: Any])
        #expect(header == ["action": "run-task", "task_id": id, "streaming": "duplex"])
        #expect(payload["task"] as? String == "asr" && payload["model"] as? String == "paraformer-realtime-v2")
        let parameters = try #require(payload["parameters"] as? [String: Any])
        #expect(parameters["sample_rate"] as? Int == 16000 && parameters["format"] as? String == "pcm")
        #expect(parameters["heartbeat"] as? Bool == true && parameters["max_sentence_silence"] as? Int == 600)
        let ready = try JSONSerialization.data(withJSONObject: ["header": ["event": "task-started", "task_id": id], "payload": [:]])
        #expect(ParaformerTranscriptionProtocol.isReady(ready, taskID: id))
        #expect(!ParaformerTranscriptionProtocol.isReady(ready, taskID: "wrong"))
        #expect(throws: CaptionFailure.self) { try ParaformerTranscriptionProtocol.event(ready, taskID: "wrong") }
        let finish = try #require(JSONSerialization.jsonObject(with: Data(ParaformerTranscriptionProtocol.finish(taskID: id).utf8)) as? [String: Any])
        #expect((finish["header"] as? [String: String])?["task_id"] == id)
        #expect((finish["header"] as? [String: String])?["action"] == "finish-task")
    }
    @Test func draftsAndFinalsShareIdentityWhileHeartbeatsAndMalformedResultsAreHandled() throws {
        func result(_ sentence: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["header": ["event": "result-generated", "task_id": "task"], "payload": ["output": ["sentence": sentence]]])
        }
        #expect(try ParaformerTranscriptionProtocol.event(result(["begin_time": 170, "text": "Hello", "sentence_end": false]), taskID: "task") == .snapshot(id: "sentence-170", text: "Hello"))
        #expect(try ParaformerTranscriptionProtocol.event(result(["begin_time": 170, "text": "Hello, everyone.", "sentence_end": true]), taskID: "task") == .completed(id: "sentence-170", text: "Hello, everyone."))
        #expect(try ParaformerTranscriptionProtocol.event(result(["heartbeat": true]), taskID: "task") == nil)
        for invalid: [String: Any] in [["begin_time": -1, "text": "Hello", "sentence_end": true], ["begin_time": 1, "text": 3, "sentence_end": true], ["begin_time": 1, "text": "Hello"], ["begin_time": 1, "text": String(repeating: "x", count: 4001), "sentence_end": true]] {
            #expect(throws: CaptionFailure.self) { try ParaformerTranscriptionProtocol.event(result(invalid), taskID: "task") }
        }
    }
    @Test func freeQuotaErrorsAreSpecificAndNeverReflectProviderMessages() throws {
        let data = Data(#"{"header":{"event":"task-failed","task_id":"task","error_code":"AllocationQuota.FreeTierOnly","error_message":"PRIVATE-ECHO"},"payload":{}}"#.utf8)
        do { _ = try ParaformerTranscriptionProtocol.event(data, taskID: "task"); Issue.record("Quota failure was accepted") }
        catch let failure as CaptionFailure {
            guard case .quotaExhausted = failure else { Issue.record("Quota was not identified"); return }
            #expect(!failure.localizedDescription.contains("PRIVATE-ECHO"))
        }
    }
}

@MainActor struct ParaformerCredentialTests {
    private final class Credentials: TranslationCredentialStore {
        var keys: [UUID: String] = [:]
        func read(_ id: UUID) throws -> String? { keys[id] }
        func write(_ key: String?, for id: UUID) throws { keys[id] = key }
    }
    @Test func switchingAliSpeechProtocolsRetainsTheSavedKeyOnlyForTheSameOrigin() throws {
        let suite = "Poieva.Paraformer.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechServiceStore(defaults: defaults, credentials: Credentials())
        var value = SpeechServiceConfiguration(name: "Mine", baseURL: SpeechServiceKind.alibabaQwen.defaultBaseURL, model: SpeechServiceKind.alibabaQwen.defaultModel, kind: .alibabaQwen)
        try store.save(value, key: "fixture-only-key", clear: false)
        value.kind = .alibabaParaformer; value.baseURL = value.kind.defaultBaseURL; value.model = value.kind.defaultModel
        try store.save(value, key: "", clear: false)
        #expect(try store.keyForTest(value, key: "", clear: false) == "fixture-only-key")
        value.baseURL = "wss://elsewhere.example.test/api-ws/v1/inference"
        #expect(throws: ServiceConfigurationFailure.self) { try store.keyForTest(value, key: "", clear: false) }
    }
}

struct CaptionInputTests {
    @Test func singleInputModesAndFileReplayOpenExactlyOneChannel() {
        #expect(CaptionAudioInput.microphone.channels == [.microphone])
        #expect(CaptionAudioInput.system.channels == [.system])
        #expect(CaptionAudioInput.both.channels == [.system, .microphone])
        for mode in CaptionAudioInput.allCases { #expect(mode.channels(isFile: true) == [.system]) }
    }
    @Test func legacyMicrophoneCheckboxCannotSilentlyRestoreTwoBillableStreams() {
        #expect(CaptionAudioInput.migrated(raw: nil, legacyMicrophone: true) == .microphone)
        #expect(CaptionAudioInput.migrated(raw: nil, legacyMicrophone: false) == .system)
        #expect(CaptionAudioInput.migrated(raw: "invalid", legacyMicrophone: true) == .microphone)
        #expect(CaptionAudioInput.migrated(raw: "both", legacyMicrophone: true) == .both)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["POIEVA_TEST_SPEECH_URL"] != nil))
@MainActor struct ParaformerSocketTests {
    private func configuration(path: String = "/api-ws/v1/inference") throws -> SpeechServiceConfiguration {
        let endpoint = try #require(ProcessInfo.processInfo.environment["POIEVA_TEST_SPEECH_URL"])
        var url = try #require(URLComponents(string: endpoint))
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") else { throw CaptionFailure.configuration }
        url.path = path; url.query = nil
        return try SpeechServiceConfiguration(name: "Public fixture", baseURL: #require(url.url?.absoluteString), model: "paraformer-realtime-v2", kind: .alibabaParaformer).validated()
    }
    @Test func realSocketSendsBinaryAudioAndDrainsTheFinalSentence() async throws {
        let socket = RealtimeTranscriber(); defer { socket.cancel() }
        try await socket.connect(configuration: configuration(), key: "fixture-only-key")
        let reading = Task { @MainActor in
            var values: [CaptionTranscriptEvent] = []
            for try await value in socket.events { values.append(value) }
            return values
        }
        try await socket.send(.append(Data(repeating: 2, count: 6400)))
        try await socket.send(.append(Data(repeating: 0, count: 6400)))
        await #expect(throws: CaptionFailure.self) { try await socket.send(.commit) }
        try await socket.finishInput()
        let values = try await reading.value
        #expect(values.contains(.snapshot(id: "sentence-0", text: "Hello,")))
        #expect(values.contains(.completed(id: "sentence-0", text: "Hello, how are you?")))
        #expect(values.last == .finished)
    }
    @Test func quotaWrongTaskAndCancellationFailBeforeAnyAudioIsSent() async throws {
        for path in ["/paraformer-quota", "/paraformer-wrong", "/paraformer-wait"] {
            let socket = RealtimeTranscriber(); defer { socket.cancel() }
            let value = try configuration(path: path)
            let connecting = Task { try await socket.connect(configuration: value, key: "fixture-only-key") }
            if path.hasSuffix("wait") { try await Task.sleep(for: .milliseconds(40)); socket.cancel() }
            await #expect(throws: Error.self) { try await connecting.value }
        }
    }
}

import Foundation

public enum CaptionTranscriptEvent: Sendable, Equatable {
    case committed(id: String, previous: String?)
    case delta(id: String, text: String)
    case snapshot(id: String, text: String)
    case completed(id: String, text: String)
    case finished
}

public enum RealtimeTranscriptionProtocol {
    public static func configuration(model: String, kind: SpeechServiceKind = .realtime) throws -> String {
        if kind == .alibabaQwen {
            return try json(["event_id": UUID().uuidString, "type": "session.update", "session": [
                "input_audio_format": "pcm", "sample_rate": 16000, "input_audio_transcription": [:],
                "turn_detection": ["type": "server_vad", "threshold": 0.0, "silence_duration_ms": 400]
            ]])
        }
        return try json(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000], "transcription": ["model": model], "turn_detection": NSNull()
        ]]]])
    }
    public static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    public static func sessionIsReady(_ data: Data, configuration: SpeechServiceConfiguration) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "session.updated", let session = root["session"] as? [String: Any] else { return false }
        if configuration.kind == .alibabaQwen {
            let detection = session["turn_detection"] as? [String: Any]
            return session["model"] as? String == configuration.model && session["modalities"] as? [String] == ["text"] &&
                ["pcm", "pcm16"].contains(session["input_audio_format"] as? String ?? "") &&
                (session["sample_rate"] == nil || session["sample_rate"] as? Int == 16000) && detection?["type"] as? String == "server_vad"
        }
        guard session["type"] as? String == "transcription", let audio = session["audio"] as? [String: Any],
              let input = audio["input"] as? [String: Any], let transcription = input["transcription"] as? [String: Any] else { return false }
        return transcription["model"] as? String == configuration.model
    }
    public static func event(_ data: Data, kind: SpeechServiceKind = .realtime) throws -> CaptionTranscriptEvent? {
        guard data.count <= 65_536, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = root["type"] as? String else { throw CaptionFailure.response }
        func identifier(_ key: String) throws -> String {
            guard let text = root[key] as? String, !text.isEmpty, text.count <= 200 else { throw CaptionFailure.response }
            return text
        }
        func text(_ key: String) throws -> String {
            guard let text = root[key] as? String, text.count <= 4_000, !text.contains("\0") else { throw CaptionFailure.response }
            return text
        }
        switch type {
        case "input_audio_buffer.committed":
            let previous = root["previous_item_id"] as? String
            guard previous?.count ?? 0 <= 200 else { throw CaptionFailure.response }
            return .committed(id: try identifier("item_id"), previous: previous)
        case "conversation.item.input_audio_transcription.delta": return .delta(id: try identifier("item_id"), text: try text("delta"))
        case "conversation.item.input_audio_transcription.text" where kind == .alibabaQwen:
            let preview = try text("text") + text("stash")
            guard preview.count <= 4_000 else { throw CaptionFailure.response }
            return .snapshot(id: try identifier("item_id"), text: preview)
        case "conversation.item.input_audio_transcription.completed": return .completed(id: try identifier("item_id"), text: try text("transcript"))
        case "session.finished" where kind == .alibabaQwen: return .finished
        case "error", "conversation.item.input_audio_transcription.failed":
            let error = root["error"] as? [String: Any], code = (error?["code"] as? String ?? "").lowercased()
            if ["invalid_api_key", "invalidapikey", "authentication_error", "permission_denied", "accessdenied"].contains(code) { throw CaptionFailure.authentication }
            if ["rate_limit_exceeded", "insufficient_quota"].contains(code) || code.hasPrefix("throttling") || code.hasPrefix("allocationquota") { throw CaptionFailure.rateLimit }
            throw CaptionFailure.response
        default: return nil
        }
    }
}

private final class CaptionSocketDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// A bounded, transcription-only socket. No reconnects, raw-error reflection,
/// cookies, disk cache, or audio logging. Capturing starts only after session.updated.
@MainActor
public final class RealtimeTranscriber {
    public let events: AsyncThrowingStream<CaptionTranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<CaptionTranscriptEvent, Error>.Continuation
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var generation = UUID()
    private var kind: SpeechServiceKind = .realtime
    private var inputFinished = false
    public var sampleRate: Int { kind.sampleRate }
    public var usesServerVAD: Bool { kind.usesServerVAD }
    public init() {
        var output: AsyncThrowingStream<CaptionTranscriptEvent, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { output = $0 }
        continuation = output
    }
    public func connect(configuration: SpeechServiceConfiguration, key: String?) async throws {
        let value = try configuration.validated()
        guard socket == nil, !Task.isCancelled else { throw CancellationError() }
        kind = value.kind; inputFinished = false
        guard !(key ?? "").contains(where: { $0.isNewline || $0 == "\0" }) else { throw CaptionFailure.configuration }
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 15; settings.timeoutIntervalForResource = 0
        let session = URLSession(configuration: settings, delegate: CaptionSocketDelegate(), delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: value.endpoint)
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let socket = session.webSocketTask(with: request); self.socket = socket; socket.maximumMessageSize = 65_536
        let id = generation
        socket.resume()
        receiver = Task { @MainActor [weak self] in await self?.receive(socket, id: id, configuration: value) }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, Error>) in
                    ready = waiting
                    timeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(15)); self?.fail(CaptionFailure.timeout) } catch {}
                    }
                    Task { @MainActor [weak self] in
                        do { try await socket.send(.string(RealtimeTranscriptionProtocol.configuration(model: value.model, kind: value.kind))) }
                        catch { if self?.generation == id { self?.fail(self?.mapped(error) ?? CaptionFailure.connection) } }
                    }
                }
            } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
            try Task.checkCancellation()
        } catch { cancel(); throw error }
    }
    private func receive(_ socket: URLSessionWebSocketTask, id: UUID, configuration: SpeechServiceConfiguration) async {
        do {
            while !Task.isCancelled, generation == id {
                let message = try await socket.receive()
                guard generation == id else { return }
                let data: Data
                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw CaptionFailure.response }
                guard data.count <= 65_536 else { throw CaptionFailure.response }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "session.updated", ready != nil {
                    guard RealtimeTranscriptionProtocol.sessionIsReady(data, configuration: configuration) else { throw CaptionFailure.response }
                    timeout?.cancel(); timeout = nil; ready?.resume(); ready = nil
                }
                if let event = try RealtimeTranscriptionProtocol.event(data, kind: configuration.kind) {
                    if case .dropped = continuation.yield(event) { throw CaptionFailure.backlog }
                    if event == .finished { continuation.finish(); close(); return }
                }
            }
        } catch { if generation == id, !Task.isCancelled { fail(mapped(error)) } }
    }
    public func send(_ action: CaptionAudioGate.Action) async throws {
        guard let socket, ready == nil, !inputFinished else { throw CaptionFailure.connection }
        let message: String
        switch action {
        case .append(let pcm):
            guard !pcm.isEmpty, pcm.count <= sampleRate * 4 / 5, pcm.count.isMultiple(of: 2) else { throw CaptionFailure.audioFormat }
            var body = ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]
            if kind == .alibabaQwen { body["event_id"] = UUID().uuidString }
            message = try RealtimeTranscriptionProtocol.json(body)
        case .commit:
            guard !usesServerVAD else { throw CaptionFailure.configuration }
            message = #"{"type":"input_audio_buffer.commit"}"#
        }
        do { try await socket.send(.string(message)); try Task.checkCancellation() }
        catch { throw mapped(error) }
    }
    /// File replay flushes the last Qwen turn and waits for session.finished.
    /// Pause/stop still cancel immediately instead of submitting additional audio.
    public func finishInput() async throws {
        guard let socket, ready == nil, !inputFinished, kind == .alibabaQwen else { throw CaptionFailure.connection }
        inputFinished = true
        do { try await socket.send(.string(RealtimeTranscriptionProtocol.json(["type": "session.finish", "event_id": UUID().uuidString]))) }
        catch { throw mapped(error) }
    }
    private func mapped(_ error: Error) -> Error {
        if error is CaptionFailure || error is CancellationError { return error }
        if let status = (socket?.response as? HTTPURLResponse)?.statusCode {
            if [401,403].contains(status) { return CaptionFailure.authentication }
            if status == 429 { return CaptionFailure.rateLimit }
            if status >= 500 { return CaptionFailure.unavailable }
        }
        return CaptionFailure.connection
    }
    private func fail(_ error: Error) {
        ready?.resume(throwing: error); ready = nil
        continuation.finish(throwing: error); close()
    }
    public func cancel() {
        ready?.resume(throwing: CancellationError()); ready = nil
        continuation.finish(); close()
    }
    private func close() {
        generation = UUID(); timeout?.cancel(); timeout = nil; receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

import Foundation

/// DashScope task protocol: JSON control frames and binary PCM audio.
public enum ParaformerTranscriptionProtocol {
    public static func start(model: String, taskID: String) throws -> String {
        try RealtimeTranscriptionProtocol.json([
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["task_group": "audio", "task": "asr", "function": "recognition", "model": model,
                "parameters": ["format": "pcm", "sample_rate": 16000, "semantic_punctuation_enabled": false,
                               "max_sentence_silence": 600, "heartbeat": true], "input": [:]]
        ])
    }
    public static func finish(taskID: String) throws -> String {
        try RealtimeTranscriptionProtocol.json(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"], "payload": ["input": [:]]])
    }
    public static func isReady(_ data: Data, taskID: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any] else { return false }
        return header["event"] as? String == "task-started" && header["task_id"] as? String == taskID
    }
    public static func event(_ data: Data, taskID: String) throws -> CaptionTranscriptEvent? {
        guard data.count <= 65_536, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any], header["task_id"] as? String == taskID,
              let event = header["event"] as? String else { throw CaptionFailure.response }
        switch event {
        case "task-started": return nil
        case "task-finished": return .finished
        case "task-failed":
            let code = (header["error_code"] as? String ?? "").lowercased()
            if code.contains("freetier") || code.contains("freequota") || code.hasPrefix("allocationquota") { throw CaptionFailure.quotaExhausted }
            if code.contains("arrears") || code.contains("insufficientbalance") { throw CaptionFailure.billing }
            if code.contains("invalidapikey") || code.contains("accessdenied") || code.contains("unauthorized") { throw CaptionFailure.authentication }
            if code.hasPrefix("throttling") { throw CaptionFailure.rateLimit }
            throw CaptionFailure.response
        case "result-generated":
            guard let payload = root["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { throw CaptionFailure.response }
            if sentence["heartbeat"] as? Bool == true { return nil }
            guard let begin = sentence["begin_time"] as? Int, begin >= 0,
                  let text = sentence["text"] as? String, text.count <= 4000, !text.contains("\0"),
                  let final = sentence["sentence_end"] as? Bool else { throw CaptionFailure.response }
            let id = "sentence-\(begin)"
            return final ? .completed(id: id, text: text) : .snapshot(id: id, text: text)
        default: return nil
        }
    }
}

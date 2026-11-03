import Combine
import Foundation

public enum CaptionFailure: LocalizedError {
    case configuration, microphone, capture, sourceGone, audioFormat, backlog, connection, timeout, authentication, rateLimit, response, unavailable, noService
    public var errorDescription: String? {
        switch self {
        case .configuration: return L10n.tr("请填写有效的识别服务名称、地址和模型。")
        case .microphone: return L10n.tr("麦克风未授权，请在系统设置中允许后重新开始。")
        case .capture: return L10n.tr("无法采集声音，请检查系统音频录制权限和声音来源。")
        case .sourceGone: return L10n.tr("声音来源已退出，请重新选择应用。")
        case .audioFormat: return L10n.tr("当前音频格式无法处理，请更换声音来源后重试。")
        case .backlog: return L10n.tr("处理速度跟不上声音，字幕已暂停，请检查网络或更换服务。")
        case .connection: return L10n.tr("语音识别连接已中断，字幕已暂停，请手动重新开始。")
        case .timeout: return L10n.tr("语音识别服务未及时响应，请检查接口后重试。")
        case .authentication: return L10n.tr("识别服务拒绝访问，请检查密钥和模型权限。")
        case .rateLimit: return L10n.tr("识别服务额度不足或请求过于频繁，请稍后重试。")
        case .response: return L10n.tr("识别服务返回了无效结果，字幕已暂停。")
        case .unavailable: return L10n.tr("识别服务暂时不可用，请稍后重试。")
        case .noService: return L10n.tr("请先添加支持 Realtime 转写的语音识别 API。")
        }
    }
}

/// A transcription-only Realtime endpoint. Never reused as a text translator.
public struct SpeechServiceConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var model: String
    public init(id: UUID = UUID(), name: String = "", baseURL: String = "", model: String = "") {
        self.id = id; self.name = name; self.baseURL = baseURL; self.model = model
    }
    public func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80, !result.model.isEmpty, result.model.count <= 200,
              !result.name.contains(where: \.isNewline), !result.model.contains(where: { $0.isWhitespace || $0.isASCII && ($0.asciiValue ?? 32) < 32 }) else { throw CaptionFailure.configuration }
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 2048, var url = URLComponents(string: raw), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.queryItems == nil || url.queryItems == [URLQueryItem(name: "intent", value: "transcription")] else { throw CaptionFailure.configuration }
        let scheme = url.scheme?.lowercased(), local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || scheme == "wss" || local && (scheme == "http" || scheme == "ws") else { throw CaptionFailure.configuration }
        url.scheme = scheme == "https" || scheme == "wss" ? "wss" : "ws"
        url.host = host.lowercased(); url.query = nil
        url.path = url.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        if url.path.isEmpty { url.path = "/v1/realtime" }
        else if url.path.hasSuffix("/v1") { url.path += "/realtime" }
        guard let canonical = url.url?.absoluteString else { throw CaptionFailure.configuration }
        result.baseURL = canonical
        return result
    }
    public var endpoint: URL {
        var url = URLComponents(string: baseURL)!
        url.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return url.url!
    }
    public var origin: String {
        let url = URLComponents(string: baseURL)!
        return "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? (url.scheme == "wss" ? 443 : 80))"
    }
}

@MainActor
public final class SpeechServiceStore: ObservableObject {
    @Published public private(set) var configurations: [SpeechServiceConfiguration] = []
    @Published public private(set) var issue = ""
    public var onChange: ((UUID) -> Void)?
    private let defaults: UserDefaults
    private let credentials: any TranslationCredentialStore
    private var keyIDs: Set<UUID> = []
    private let storageKey = "speechServices.v1"
    private struct Saved: Codable { var configurations: [SpeechServiceConfiguration]; var keyIDs: Set<UUID> }
    public init(defaults: UserDefaults, credentials: any TranslationCredentialStore) {
        self.defaults = defaults; self.credentials = credentials
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            guard data.count <= 262_144 else { throw CaptionFailure.configuration }
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            let values = try saved.configurations.map { try $0.validated() }
            guard values.count <= 50, Set(values.map(\.id)).count == values.count else { throw CaptionFailure.configuration }
            configurations = values; keyIDs = saved.keyIDs.intersection(Set(values.map(\.id)))
        } catch { issue = L10n.tr("语音识别配置无法读取，原记录已保留。") }
    }
    public func hasKey(_ id: UUID) -> Bool { keyIDs.contains(id) }
    public func key(for id: UUID) throws -> String? {
        guard configurations.contains(where: { $0.id == id }), keyIDs.contains(id) else { return nil }
        return try credentials.read(id)
    }
    public func prepareForSave(_ draft: SpeechServiceConfiguration, key: String, clear: Bool) async throws {
        let value = try draft.validated()
        try validateReuse(value, key: key, clear: clear)
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !clear, hasKey(value.id) {
            guard try await credentials.prepareForSave(value.id) != nil else { throw ServiceConfigurationFailure.credential }
        }
    }
    public func keyForTest(_ draft: SpeechServiceConfiguration, key: String, clear: Bool) throws -> String? {
        let value = try draft.validated(), key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateReuse(value, key: key, clear: clear)
        return clear ? nil : (!key.isEmpty ? key : try self.key(for: value.id))
    }
    private func validateReuse(_ value: SpeechServiceConfiguration, key: String, clear: Bool) throws {
        if let old = configurations.first(where: { $0.id == value.id }), old.origin != value.origin,
           hasKey(value.id), key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !clear {
            throw ServiceConfigurationFailure.invalid(L10n.tr("服务地址已更改，请重新填写密钥，或清除已保存的密钥。"))
        }
    }
    public func save(_ draft: SpeechServiceConfiguration, key: String, clear: Bool) throws {
        let value = try draft.validated(), key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateReuse(value, key: key, clear: clear)
        guard !key.contains(where: { $0.isNewline || $0 == "\0" }), configurations.count < 50 || configurations.contains(where: { $0.id == value.id }) else { throw CaptionFailure.configuration }
        if clear || !key.isEmpty {
            try credentials.write(clear ? nil : key, for: value.id)
            if clear { keyIDs.remove(value.id) } else { keyIDs.insert(value.id) }
        }
        if let index = configurations.firstIndex(where: { $0.id == value.id }) { configurations[index] = value }
        else { configurations.append(value) }
        persist(); onChange?(value.id)
    }
    public func remove(_ id: UUID) throws {
        guard configurations.contains(where: { $0.id == id }) else { return }
        if hasKey(id) { try credentials.write(nil, for: id) }
        configurations.removeAll { $0.id == id }; keyIDs.remove(id); persist(); onChange?(id)
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(Saved(configurations: configurations, keyIDs: keyIDs)) else { return }
        defaults.set(data, forKey: storageKey); issue = ""
    }
}

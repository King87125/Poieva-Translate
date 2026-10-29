import Foundation

public enum ServiceConfigurationFailure: LocalizedError {
    case invalid(String), unsupportedVersion, unsupportedAdapter, oversized, damagedFile, busy, credential, credentialAuthorization
    public var errorDescription: String? {
        switch self {
        case let .invalid(reason): return reason
        case .unsupportedVersion: return L10n.tr("此配置文件的版本暂不支持。")
        case .unsupportedAdapter: return L10n.tr("此版本暂不支持配置中的适配器。")
        case .oversized: return L10n.tr("配置文件过大，最多支持 256 KB、50 个服务。")
        case .damagedFile: return L10n.tr("无法读取配置文件，请选择 Poieva Translate 导出的 JSON 文件。")
        case .busy: return L10n.tr("正在提交替换，请稍后修改服务。")
        case .credential: return L10n.tr("无法访问钥匙串中的密钥，请重新填写后保存。")
        case .credentialAuthorization: return L10n.tr("暂时无法读取已保存的密钥。旧版配置请打开后点「保存」完成一次迁移；若电脑已锁定，请先解锁。")
        }
    }
}

public indirect enum ServiceJSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: ServiceJSONValue]), array([ServiceJSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: ServiceJSONValue].self) { self = .object(value) }
        else { self = .array(try c.decode([ServiceJSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var foundationValue: Any {
        switch self {
        case let .string(v): return v
        case let .number(v): return v
        case let .bool(v): return v
        case let .object(v): return v.mapValues(\.foundationValue)
        case let .array(v): return v.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

public enum TranslationServiceAdapter: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAICompatible = "openai-chat-completions"
    case deepL = "deepl"
    case baidu = "baidu-translate"
    case youdao = "youdao-v3"
    case customHTTP = "custom-http"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .openAICompatible: return L10n.tr("OpenAI 兼容")
        case .deepL: return "DeepL"
        case .baidu: return L10n.tr("百度通用翻译")
        case .youdao: return L10n.tr("有道文本翻译")
        case .customHTTP: return L10n.tr("自定义 HTTP 翻译")
        }
    }
    public var defaultURL: String {
        switch self {
        case .openAICompatible, .customHTTP: return ""
        case .deepL: return "https://api.deepl.com/v2/translate"
        case .baidu: return "https://fanyi-api.baidu.com/api/trans/vip/translate"
        case .youdao: return "https://openapi.youdao.com/api"
        }
    }
    public var needsAppID: Bool { self == .baidu || self == .youdao }
    public var keyLabel: String {
        switch self {
        case .openAICompatible: return L10n.tr("密钥（可选）")
        case .deepL: return "API Key"
        case .baidu: return L10n.tr("密钥")
        case .youdao: return L10n.tr("应用密钥")
        case .customHTTP: return "API Key"
        }
    }
}

/// Contains no credentials. IDs are local identities and never imported from a package.
public struct TranslationServiceConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var adapter: TranslationServiceAdapter
    public var baseURL: String
    public var model: String
    public var appID: String
    public var jsonMode: Bool
    public var parameters: [String: ServiceJSONValue]
    public var http: HTTPTranslationTemplate?

    /// The auxiliary model runs remotely. Loopback APIs remain available for
    /// development/basic translators, but never selected as an auxiliary model.
    public var isRemoteModelAPI: Bool {
        guard adapter == .openAICompatible, let url = URLComponents(string: baseURL),
              url.scheme?.lowercased() == "https", let rawHost = url.host else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return !host.isEmpty && host != "localhost" && !host.hasSuffix(".localhost") &&
            !host.hasPrefix("127.") && !["0.0.0.0", "::1", "::"].contains(host)
    }

    public init(id: UUID = UUID(), name: String = "", adapter: TranslationServiceAdapter = .openAICompatible,
                baseURL: String = "", model: String = "", jsonMode: Bool = false,
                parameters: [String: ServiceJSONValue] = [:], appID: String = "", http: HTTPTranslationTemplate? = nil) {
        self.id = id; self.name = name; self.adapter = adapter; self.baseURL = baseURL
        self.model = model; self.jsonMode = jsonMode; self.parameters = parameters; self.appID = appID
        self.http = http
    }

    private enum CodingKeys: String, CodingKey { case id, name, adapter, baseURL, model, appID, jsonMode, parameters, http }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        adapter = try c.decode(TranslationServiceAdapter.self, forKey: .adapter)
        baseURL = try c.decode(String.self, forKey: .baseURL); model = try c.decode(String.self, forKey: .model)
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        jsonMode = try c.decode(Bool.self, forKey: .jsonMode)
        parameters = try c.decode([String: ServiceJSONValue].self, forKey: .parameters)
        http = try c.decodeIfPresent(HTTPTranslationTemplate.self, forKey: .http)
    }

    public func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80 else { throw ServiceConfigurationFailure.invalid(L10n.tr("请填写服务名称，最多 80 字。")) }
        guard adapter != .openAICompatible || !result.model.isEmpty, result.model.count <= 200, !result.model.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("请填写有效的模型名称。"))
        }
        if adapter.needsAppID {
            guard !result.appID.isEmpty, result.appID.count <= 128,
                  result.appID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                throw ServiceConfigurationFailure.invalid(L10n.tr("请填写有效的应用 ID。"))
            }
        } else { result.appID = "" }
        if adapter != .openAICompatible {
            guard model.isEmpty, !jsonMode else { throw ServiceConfigurationFailure.invalid(L10n.tr("此服务不使用模型名称或 JSON 输出模式。")) }
        }
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 2048, let components = URLComponents(string: raw),
              let host = components.host, !host.isEmpty, let scheme = components.scheme?.lowercased(),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.url != nil else { throw ServiceConfigurationFailure.invalid(L10n.tr("请填写不含账号、密码、查询参数的完整服务地址。")) }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || scheme == "http" && local else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("远程服务请使用 HTTPS；HTTP 仅用于本机 localhost 或回环地址。"))
        }
        var normalized = components
        normalized.scheme = scheme; normalized.host = host.lowercased()
        guard let canonical = normalized.url?.absoluteString else { throw ServiceConfigurationFailure.invalid(L10n.tr("服务地址无效。")) }
        result.baseURL = canonical.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        if adapter == .deepL {
            let path = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.isEmpty { result.baseURL += "/v2/translate" }
            else if path == "v2" { result.baseURL += "/translate" }
        }
        guard let encoded = try? JSONEncoder().encode(parameters), encoded.count <= 16_384 else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("高级参数最多支持 16 KB。"))
        }
        let reserved: Set<String> = ["messages", "model", "stream", "stream_options", "n", "response_format", "tools", "tool_choice", "functions", "function_call", "input", "prompt", "store", "headers"]
        guard adapter == .customHTTP || parameters.keys.allSatisfy({ !reserved.contains($0.lowercased()) }) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("高级参数不能覆盖模型、消息、输出格式、工具或请求头。"))
        }
        try Self.validateParameters(.object(parameters), depth: 0)
        if adapter == .customHTTP {
            guard !raw.contains("{{"), !raw.contains("}}"), let http else { throw ServiceConfigurationFailure.invalid(L10n.tr("请填写接口模板；服务地址不支持占位符。")) }
            try http.validate(parameters: parameters)
        } else {
            guard http == nil else { throw ServiceConfigurationFailure.invalid(L10n.tr("此服务类型不使用 HTTP 接口模板。")) }
            if adapter != .openAICompatible { try validateProfessionalParameters() }
        }
        return result
    }

    private func validateProfessionalParameters() throws {
        let allowed: Set<String>
        switch adapter {
        case .deepL: allowed = ["formality", "model_type"]
        case .baidu: allowed = ["action"]
        case .youdao: allowed = ["domain", "vocabId"]
        case .openAICompatible, .customHTTP: return
        }
        guard Set(parameters.keys).isSubset(of: allowed) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("高级参数包含此服务不支持的字段。"))
        }
        let choices: [String: Set<String>] = [
            "formality": ["default", "more", "less", "prefer_more", "prefer_less"],
            "model_type": ["quality_optimized", "prefer_quality_optimized", "latency_optimized"],
            "domain": ["general", "computers", "medicine", "finance", "game"]]
        for (key, value) in parameters {
            if let choices = choices[key] {
                guard case let .string(text) = value, choices.contains(text) else {
                    throw ServiceConfigurationFailure.invalid(L10n.tr("高级参数 \(key) 的取值无效。"))
                }
            } else if key == "action" {
                guard value == .number(0) || value == .number(1) else { throw ServiceConfigurationFailure.invalid(L10n.tr("术语干预 action 仅支持 0 或 1。")) }
            } else if key == "vocabId" {
                guard case let .string(text) = value, text.count <= 200, !text.contains(where: { $0.isNewline }) else {
                    throw ServiceConfigurationFailure.invalid(L10n.tr("术语表 ID 无效。"))
                }
            }
        }
    }

    public var endpoint: URL {
        let base = URL(string: baseURL)!
        if adapter == .openAICompatible { return base.path.hasSuffix("/chat/completions") ? base : base.appendingPathComponent("chat/completions") }
        return base
    }
    public var origin: String {
        guard let c = URLComponents(string: baseURL) else { return "" }
        return "\(c.scheme?.lowercased() ?? "")://\(c.host?.lowercased() ?? ""):\(c.port ?? (c.scheme == "http" ? 80 : 443))"
    }
    public var parametersText: String {
        guard !parameters.isEmpty else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(parameters)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    public static func parseParameters(_ text: String) throws -> [String: ServiceJSONValue] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard text.utf8.count <= 16_384, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: ServiceJSONValue].self, from: data) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("高级参数必须是 JSON 对象，例如 {\"temperature\":0}。"))
        }
        return value
    }
    static func validateParameters(_ value: ServiceJSONValue, depth: Int) throws {
        guard depth <= 8 else { throw ServiceConfigurationFailure.invalid(L10n.tr("高级参数嵌套过深。")) }
        switch value {
        case let .object(values):
            for (key, child) in values {
                let key = key.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                guard !["apikey", "authorization", "secret", "password", "accesstoken", "credential", "headers"].contains(key) else {
                    throw ServiceConfigurationFailure.invalid(L10n.tr("密钥请填写在密钥栏中，不要放入高级参数。"))
                }
                try validateParameters(child, depth: depth + 1)
            }
        case let .array(values): for child in values { try validateParameters(child, depth: depth + 1) }
        case let .number(number): guard number.isFinite else { throw ServiceConfigurationFailure.invalid(L10n.tr("高级参数包含无效数字。")) }
        default: break
        }
    }
}

public enum TranslationServicePackage {
    public static let maximumBytes = 262_144
    private struct File: Codable {
        var format = "typebridge.translation-services"
        var version = 3
        var services: [Entry]
    }
    private struct Entry: Codable {
        var name: String
        var adapter: String
        var baseURL: String
        var model: String
        var jsonMode: Bool
        var parameters: [String: ServiceJSONValue]
        var appID: String?
        var http: HTTPTranslationTemplate?
    }
    public static func encode(_ configurations: [TranslationServiceConfiguration]) throws -> Data {
        guard !configurations.isEmpty, configurations.count <= 50 else { throw ServiceConfigurationFailure.oversized }
        let entries = try configurations.map { configuration -> Entry in
            let c = try configuration.validated()
            return Entry(name: c.name, adapter: c.adapter.rawValue, baseURL: c.baseURL, model: c.model, jsonMode: c.jsonMode, parameters: c.parameters, appID: c.appID, http: c.http)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(services: entries))
        guard data.count <= maximumBytes else { throw ServiceConfigurationFailure.oversized }
        return data
    }
    public static func decode(_ data: Data) throws -> [TranslationServiceConfiguration] {
        guard data.count <= maximumBytes else { throw ServiceConfigurationFailure.oversized }
        // Reject secret-bearing/unknown fields instead of silently importing embedded credentials.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["format", "version", "services"],
              let rawEntries = root["services"] as? [[String: Any]],
              rawEntries.allSatisfy({ entry in
                  let required: Set<String> = ["name", "adapter", "baseURL", "model", "jsonMode", "parameters"]
                  return required.isSubset(of: Set(entry.keys)) && Set(entry.keys).isSubset(of: required.union(["appID", "http"]))
              }),
              let file = try? JSONDecoder().decode(File.self, from: data), file.format == "typebridge.translation-services" else {
            throw ServiceConfigurationFailure.damagedFile
        }
        guard (1...3).contains(file.version) else { throw ServiceConfigurationFailure.unsupportedVersion }
        if file.version == 1 {
            guard file.services.allSatisfy({ $0.adapter == TranslationServiceAdapter.openAICompatible.rawValue && $0.appID == nil && $0.http == nil }) else { throw ServiceConfigurationFailure.damagedFile }
        }
        if file.version < 3 { guard rawEntries.allSatisfy({ $0["http"] == nil && $0["adapter"] as? String != "custom-http" }) else { throw ServiceConfigurationFailure.damagedFile } }
        guard !file.services.isEmpty, file.services.count <= 50 else { throw ServiceConfigurationFailure.oversized }
        return try file.services.map { entry in
            guard let adapter = TranslationServiceAdapter(rawValue: entry.adapter) else { throw ServiceConfigurationFailure.unsupportedAdapter }
            return try TranslationServiceConfiguration(name: entry.name, adapter: adapter, baseURL: entry.baseURL,
                model: entry.model, jsonMode: entry.jsonMode, parameters: entry.parameters, appID: entry.appID ?? "", http: entry.http).validated()
        }
    }
}

import Foundation

private struct TemplateField: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireTemplateFields(_ decoder: Decoder, _ allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: TemplateField.self).allKeys.map(\.stringValue)
    guard Set(keys).isSubset(of: allowed) else {
        throw ServiceConfigurationFailure.invalid(L10n.tr("接口模板包含未知字段，请检查模板版本；密钥应填写在密钥栏。"))
    }
}

public enum HTTPTranslationAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case bearer, header, none
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .bearer: return "Bearer API Key"
        case .header: return L10n.tr("自定义密钥请求头")
        case .none: return L10n.tr("无需密钥")
        }
    }
}

public struct HTTPTranslationOptionChoice: Codable, Equatable, Sendable {
    public var value: String
    public var title: String
    public var languageCodes: [String: String]?
    public var sourceLanguageCodes: [String: String]?
    public init(value: String, title: String, languageCodes: [String: String]? = nil, sourceLanguageCodes: [String: String]? = nil) {
        self.value = value; self.title = title; self.languageCodes = languageCodes; self.sourceLanguageCodes = sourceLanguageCodes
    }
    private enum CodingKeys: String, CodingKey { case value, title, languageCodes, sourceLanguageCodes }
    public init(from decoder: Decoder) throws {
        try requireTemplateFields(decoder, ["value", "title", "languageCodes", "sourceLanguageCodes"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(String.self, forKey: .value); title = try c.decode(String.self, forKey: .title)
        languageCodes = try c.decodeIfPresent([String: String].self, forKey: .languageCodes)
        sourceLanguageCodes = try c.decodeIfPresent([String: String].self, forKey: .sourceLanguageCodes)
    }
}

public struct HTTPTranslationOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var defaultValue: String
    public var choices: [HTTPTranslationOptionChoice]
    public init(id: String, title: String, defaultValue: String, choices: [HTTPTranslationOptionChoice]) {
        self.id = id; self.title = title; self.defaultValue = defaultValue; self.choices = choices
    }
    private enum CodingKeys: String, CodingKey { case id, title, defaultValue, choices }
    public init(from decoder: Decoder) throws {
        try requireTemplateFields(decoder, ["id", "title", "defaultValue", "choices"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        defaultValue = try c.decode(String.self, forKey: .defaultValue)
        choices = try c.decode([HTTPTranslationOptionChoice].self, forKey: .choices)
    }
}

/// Declarative JSON data only. Templates cannot execute code or put credentials in a URL/body.
public struct HTTPTranslationTemplate: Codable, Equatable, Sendable {
    public var version = 1
    public var method = "POST"
    public var authentication: HTTPTranslationAuthentication = .bearer
    public var keyHeader = "X-API-Key"
    public var keyPrefix = ""
    public var request: [String: ServiceJSONValue] = ["text": .string("{{text}}"), "source": .string("{{source}}"), "target": .string("{{target}}")]
    public var responsePath = "data.translatedText"
    public var successPath = ""
    public var successValue: ServiceJSONValue = .number(200)
    public var errorMessages: [String: String] = [:]
    public var languageCodes: [String: String] = Dictionary(uniqueKeysWithValues: AppLanguage.targets.map { ($0.rawValue, $0.rawValue) })
    public var sourceLanguageCodes: [String: String] = [:]
    public var options: [HTTPTranslationOption] = []
    /// Conservative UTF-16 units per client fragment; not a claim about a vendor's limit.
    public var maxCharacters = 2_000
    public init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, method, authentication, keyHeader, keyPrefix, request, responsePath, successPath, successValue, errorMessages, languageCodes, sourceLanguageCodes, options, maxCharacters
    }
    public init(from decoder: Decoder) throws {
        try requireTemplateFields(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "POST"
        authentication = try c.decodeIfPresent(HTTPTranslationAuthentication.self, forKey: .authentication) ?? .bearer
        keyHeader = try c.decodeIfPresent(String.self, forKey: .keyHeader) ?? "X-API-Key"
        keyPrefix = try c.decodeIfPresent(String.self, forKey: .keyPrefix) ?? ""
        request = try c.decode([String: ServiceJSONValue].self, forKey: .request)
        responsePath = try c.decode(String.self, forKey: .responsePath)
        successPath = try c.decodeIfPresent(String.self, forKey: .successPath) ?? ""
        successValue = c.contains(.successValue) ? try c.decode(ServiceJSONValue.self, forKey: .successValue) : .number(200)
        errorMessages = try c.decodeIfPresent([String: String].self, forKey: .errorMessages) ?? [:]
        languageCodes = try c.decode([String: String].self, forKey: .languageCodes)
        sourceLanguageCodes = try c.decodeIfPresent([String: String].self, forKey: .sourceLanguageCodes) ?? [:]
        options = try c.decodeIfPresent([HTTPTranslationOption].self, forKey: .options) ?? []
        maxCharacters = try c.decodeIfPresent(Int.self, forKey: .maxCharacters) ?? 2_000
    }
    public var credentialScope: String {
        switch authentication {
        case .none: return "none"
        case .bearer: return "bearer"
        case .header: return "header|\(keyHeader.lowercased())|\(keyPrefix)"
        }
    }
    public var jsonText: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 32_768, let data = text.data(using: .utf8) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("接口模板最多支持 32 KB。"))
        }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch let failure as ServiceConfigurationFailure { throw failure }
        catch { throw ServiceConfigurationFailure.invalid(L10n.tr("接口模板必须是有效的 JSON 对象，请检查字段与类型。")) }
        try value.validate(parameters: [:])
        return value
    }
    public func validate(parameters: [String: ServiceJSONValue]) throws {
        guard version == 1 else { throw ServiceConfigurationFailure.unsupportedVersion }
        guard method == "POST" else { throw ServiceConfigurationFailure.invalid(L10n.tr("此版本的自定义接口支持 POST JSON 请求。")) }
        guard (1...20_000).contains(maxCharacters), try JSONEncoder().encode(self).count <= 32_768 else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("接口模板最多 32 KB，单次文字上限须为 1–20,000。"))
        }
        let protectedHeaders = ["host", "cookie", "set-cookie", "content-length", "content-type", "accept", "connection", "origin", "referer", "transfer-encoding"]
        guard !keyHeader.isEmpty, keyHeader.count <= 80,
              keyHeader.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !protectedHeaders.contains(keyHeader.lowercased()), !keyHeader.lowercased().hasPrefix("sec-"), !keyHeader.lowercased().hasPrefix("proxy-"),
              keyPrefix.utf8.count <= 80, keyPrefix.allSatisfy({ $0.isASCII && !$0.isNewline && ($0.asciiValue ?? 0) >= 32 }), !keyPrefix.contains("{{") else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("密钥请求头或前缀无效；请勿覆盖系统请求头。"))
        }
        try Self.validateCodes(languageCodes)
        try Self.validateCodes(sourceLanguageCodes, allowEmpty: true)
        guard options.count <= 8, Set(options.map(\.id)).count == options.count else { throw ServiceConfigurationFailure.invalid(L10n.tr("接口选项最多 8 项，名称不能重复。")) }
        for option in options {
            guard Self.identifier(option.id, maximum: 40), !["text", "source", "target"].contains(option.id),
                  Self.label(option.title, maximum: 80), !option.choices.isEmpty, option.choices.count <= 50,
                  Set(option.choices.map(\.value)).count == option.choices.count,
                  option.choices.contains(where: { $0.value == option.defaultValue }) else {
                throw ServiceConfigurationFailure.invalid(L10n.tr("接口选项的名称、候选值或默认值无效。"))
            }
            try TranslationServiceConfiguration.validateParameters(.object([option.id: .null]), depth: 0)
            for choice in option.choices {
                guard Self.label(choice.value, maximum: 200), Self.label(choice.title, maximum: 80) else { throw ServiceConfigurationFailure.invalid(L10n.tr("接口选项的候选值无效。")) }
                if let codes = choice.languageCodes { try Self.validateCodes(codes) }
                if let codes = choice.sourceLanguageCodes { try Self.validateCodes(codes, allowEmpty: true) }
            }
        }
        guard Set(parameters.keys).isSubset(of: Set(options.map(\.id))) else { throw ServiceConfigurationFailure.invalid(L10n.tr("参数包含接口模板未定义的选项。")) }
        for (key, value) in parameters {
            guard case let .string(selected) = value, options.first(where: { $0.id == key })?.choices.contains(where: { $0.value == selected }) == true else {
                throw ServiceConfigurationFailure.invalid(L10n.tr("接口选项的取值不在模板定义中。"))
            }
        }
        try TranslationServiceConfiguration.validateParameters(.object(request), depth: 0)
        let tokens = try Self.tokens(in: .object(request))
        let allowed = Set(["text", "source", "target"] + options.map { "option." + $0.id })
        guard tokens.contains("text"), tokens.contains("target"), tokens.isSubset(of: allowed) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("请求模板需要 {{text}} 与 {{target}}；其他占位符只能为 {{source}} 或已定义的 {{option.名称}}。"))
        }
        guard Self.validPath(responsePath), successPath.isEmpty || Self.validPath(successPath), errorMessages.count <= 32,
              errorMessages.allSatisfy({ Self.identifier($0.key, maximum: 32) && Self.label($0.value, maximum: 200) }) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("译文/成功状态的字段路径或错误提示无效。"))
        }
        switch successValue {
        case .string(let value): guard Self.label(value, maximum: 80) else { throw ServiceConfigurationFailure.invalid(L10n.tr("成功状态取值无效。")) }
        case .number(let value): guard value.isFinite else { throw ServiceConfigurationFailure.invalid(L10n.tr("成功状态取值无效。")) }
        case .bool, .null: break
        default: throw ServiceConfigurationFailure.invalid(L10n.tr("成功状态应为数字、文字、布尔值或 null。"))
        }
    }
    public func selectedValue(for option: HTTPTranslationOption, parameters: [String: ServiceJSONValue]) -> String {
        if case let .string(value) = parameters[option.id] { return value }
        return option.defaultValue
    }
    public func codes(parameters: [String: ServiceJSONValue]) -> [String: String] {
        var codes = languageCodes
        for option in options {
            if let replacement = option.choices.first(where: { $0.value == selectedValue(for: option, parameters: parameters) })?.languageCodes { codes = replacement }
        }
        return codes
    }
    public func render(text: String, source: AppLanguage, target: AppLanguage, parameters: [String: ServiceJSONValue]) throws -> ServiceJSONValue {
        let codes = codes(parameters: parameters)
        guard let targetCode = codes[target.rawValue] else { throw HTTPTranslationFailure.language(target) }
        var sourceCodes = codes.merging(sourceLanguageCodes) { _, new in new }
        for option in options {
            if let overrides = option.choices.first(where: { $0.value == selectedValue(for: option, parameters: parameters) })?.sourceLanguageCodes {
                sourceCodes.merge(overrides) { _, new in new }
            }
        }
        let tokens = try Self.tokens(in: .object(request))
        if tokens.contains("source"), sourceCodes[source.rawValue] == nil { throw HTTPTranslationFailure.language(source) }
        var replacements = ["text": text, "source": sourceCodes[source.rawValue] ?? source.rawValue, "target": targetCode]
        for option in options { replacements["option." + option.id] = selectedValue(for: option, parameters: parameters) }
        return try Self.substitute(.object(request), replacements: replacements)
    }
    static func field(_ path: String, in value: ServiceJSONValue) -> ServiceJSONValue? {
        var current = value
        for part in path.split(separator: ".") {
            switch current {
            case let .object(object): guard let next = object[String(part)] else { return nil }; current = next
            case let .array(array): guard let index = Int(part), index >= 0, index < array.count else { return nil }; current = array[index]
            default: return nil
            }
        }
        return current
    }
    private static func validateCodes(_ codes: [String: String], allowEmpty: Bool = false) throws {
        guard allowEmpty || !codes.isEmpty, codes.count <= AppLanguage.allCases.count,
              codes.allSatisfy({ AppLanguage(rawValue: $0.key) != nil && identifier($0.value, maximum: 32) }) else {
            throw ServiceConfigurationFailure.invalid(L10n.tr("语言代码需使用应用语言标识映射到接口语言代码。"))
        }
    }
    private static func identifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
    private static func label(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maximum && !value.contains { $0.isNewline || $0.isASCII && ($0.asciiValue ?? 0) < 32 }
    }
    private static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false)
        return path.count <= 256 && parts.count <= 16 && parts.allSatisfy { identifier(String($0), maximum: 80) }
    }
    private static let placeholder = try! NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
    private static func tokens(in value: ServiceJSONValue) throws -> Set<String> {
        switch value {
        case let .object(object):
            guard object.keys.allSatisfy({ !$0.contains("{{") && !$0.contains("}}") }) else { throw ServiceConfigurationFailure.invalid(L10n.tr("请求字段名不能使用占位符。")) }
            return try object.values.reduce(into: Set<String>()) { $0.formUnion(try tokens(in: $1)) }
        case let .array(array): return try array.reduce(into: Set<String>()) { $0.formUnion(try tokens(in: $1)) }
        case let .string(string):
            let range = NSRange(string.startIndex..., in: string)
            let matches = placeholder.matches(in: string, range: range)
            let remaining = placeholder.stringByReplacingMatches(in: string, range: range, withTemplate: "")
            guard !remaining.contains("{{") && !remaining.contains("}}") else { throw ServiceConfigurationFailure.invalid(L10n.tr("请求模板含有未闭合的占位符。")) }
            return Set(matches.compactMap { Range($0.range(at: 1), in: string).map { String(string[$0]) } })
        default: return []
        }
    }
    private static func substitute(_ value: ServiceJSONValue, replacements: [String: String]) throws -> ServiceJSONValue {
        switch value {
        case let .object(object): return .object(try object.mapValues { try substitute($0, replacements: replacements) })
        case let .array(array): return .array(try array.map { try substitute($0, replacements: replacements) })
        case let .string(string):
            var output = "", cursor = string.startIndex
            for match in placeholder.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
                guard let whole = Range(match.range, in: string), let name = Range(match.range(at: 1), in: string),
                      let replacement = replacements[String(string[name])] else { throw ServiceConfigurationFailure.invalid(L10n.tr("接口占位符无效。")) }
                output += string[cursor..<whole.lowerBound]; output += replacement; cursor = whole.upperBound
            }
            output += string[cursor...]
            return .string(output)
        default: return value
        }
    }
}

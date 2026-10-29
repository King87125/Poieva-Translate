import CryptoKit
import Foundation

enum TranslationServiceSigning {
    static func baidu(appID: String, query: String, salt: String, key: String) -> String {
        // MD5 is mandated by this API's wire protocol; it is not used to store credentials.
        Insecure.MD5.hash(data: Data((appID + query + salt + key).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func youdao(appID: String, query: String, salt: String, timestamp: String, key: String) -> String {
        let scalars = Array(query.unicodeScalars)
        let input = scalars.count <= 20 ? query : String(String.UnicodeScalarView(scalars.prefix(10))) + String(scalars.count) + String(String.UnicodeScalarView(scalars.suffix(10)))
        return SHA256.hash(data: Data((appID + input + salt + timestamp + key).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let value = fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        return Data(value.utf8)
    }
}

public enum ProfessionalTranslationFailure: LocalizedError {
    case missingKey, invalidResponse, segmentTooLong, service(TranslationServiceAdapter, String)
    public var errorDescription: String? {
        switch self {
        case .missingKey: return L10n.tr("请先在服务配置中填写自己的密钥。")
        case .invalidResponse: return L10n.tr("服务返回的译文不完整或段落不匹配，原文已保留。")
        case .segmentTooLong: return L10n.tr("这段文字超过服务单次请求限制，请缩短后重试。")
        case let .service(adapter, code):
            let reason: String
            switch (adapter, code) {
            case (.deepL, "456"): reason = L10n.tr("翻译额度已用完，请检查账户用量。")
            case (.baidu, "52003"), (.baidu, "54001"), (.baidu, "58000"), (.baidu, "58002"),
                 (.youdao, "108"), (.youdao, "110"), (.youdao, "111"), (.youdao, "202"), (.youdao, "205"):
                reason = L10n.tr("请检查应用 ID、密钥及是否已开通对应翻译服务。")
            case (.baidu, "54003"), (.baidu, "54005"), (.youdao, "411"), (.youdao, "412"):
                reason = L10n.tr("请求过于频繁，请稍后重试。")
            case (.baidu, "54004"), (.baidu, "54006"), (.youdao, "401"):
                reason = L10n.tr("账户余额或额度不足，请检查服务账户。")
            case (.baidu, "58001"), (.youdao, "102"):
                reason = L10n.tr("此服务暂不支持当前语言组合。")
            case (.youdao, "206"): reason = L10n.tr("请求时间无效，请检查 Mac 的日期与时间。")
            case (.youdao, "310"): reason = L10n.tr("尚未开通所选领域翻译，请检查配置。")
            default: reason = L10n.tr("服务暂时无法完成翻译，请检查配置或稍后重试。")
            }
            let safeCode = !code.isEmpty && code.count <= 8 && code.allSatisfy(\.isNumber) ? "（\(code)）" : ""
            return "\(adapter.name)\(safeCode)：\(reason)"
        }
    }
}

/// A fragment keeps its original boundary whitespace. Splitting never changes paragraph layout.
struct ProfessionalTranslationPlan {
    struct Fragment {
        var original: Int
        var text: String
        var prefix: String
        var suffix: String
    }
    let originals: [String]
    var fragments: [Fragment] = []
    init(texts: [String], adapter: TranslationServiceAdapter, maximumUnits: Int? = nil) throws {
        originals = texts
        // The free Baidu standard tier accepts 1,000 characters, below the general API byte ceiling.
        let limit = maximumUnits ?? (adapter == .baidu ? 1_000 : adapter == .youdao ? 4_800 : 90_000)
        func size(_ character: Character) -> Int { adapter == .youdao || adapter == .baidu || adapter == .customHTTP ? String(character).utf16.count : String(character).utf8.count }
        for (index, text) in texts.enumerated() {
            guard !text.contains(where: { $0.isNewline }) else { throw ProfessionalTranslationFailure.invalidResponse }
            var start = text.startIndex
            var pendingWhitespace = ""
            while start < text.endIndex {
                var end = start, count = 0
                var boundary: String.Index?
                while end < text.endIndex, count + size(text[end]) <= limit {
                    let character = text[end]
                    count += size(character); end = text.index(after: end)
                    if count > limit / 2, character.isWhitespace || ".!?。！？;；".contains(character) { boundary = end }
                }
                guard end != start else { throw ProfessionalTranslationFailure.segmentTooLong }
                if end < text.endIndex, let boundary { end = boundary }
                let raw = String(text[start..<end])
                let prose = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty {
                    fragments.append(Fragment(original: index, text: prose,
                        prefix: pendingWhitespace + String(raw.prefix(while: \.isWhitespace)),
                        suffix: String(raw.reversed().prefix(while: \.isWhitespace).reversed())))
                    pendingWhitespace = ""
                } else { pendingWhitespace += raw }
                start = end
            }
            if !pendingWhitespace.isEmpty, let last = fragments.indices.last, fragments[last].original == index { fragments[last].suffix += pendingWhitespace }
        }
    }
    func assemble(_ values: [String], target: AppLanguage) throws -> [String] {
        guard values.count == fragments.count else { throw ProfessionalTranslationFailure.invalidResponse }
        var results = Array(repeating: "", count: originals.count)
        let usesWordSpaces = ![AppLanguage.simplifiedChinese, .traditionalChinese, .japanese].contains(target)
        for (index, fragment) in fragments.enumerated() {
            let translated = values[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty, !translated.contains(where: { $0.isNewline }) else { throw ProfessionalTranslationFailure.invalidResponse }
            if usesWordSpaces, fragment.prefix.isEmpty, results[fragment.original].last?.isLetter == true, translated.first?.isLetter == true {
                results[fragment.original] += " "
            }
            results[fragment.original] += fragment.prefix + translated + fragment.suffix
        }
        return results.indices.map { results[$0].isEmpty ? originals[$0] : results[$0] }
    }
}

@MainActor
public enum TranslationServiceFactory {
    public static func make(configuration: TranslationServiceConfiguration, session: URLSession? = nil,
                            credential: @escaping @MainActor () throws -> String? = { nil }) throws -> any TranslationProvider {
        switch configuration.adapter {
        case .openAICompatible: return try CompatibleTranslationProvider(configuration: configuration, session: session, credential: credential)
        case .deepL, .baidu, .youdao: return try ProfessionalTranslationProvider(configuration: configuration, session: session, credential: credential)
        case .customHTTP: return try HTTPTranslationProvider(configuration: configuration, session: session, credential: credential)
        }
    }
}

@MainActor
public final class ProfessionalTranslationProvider: TranslationProvider {
    public var name: String { configuration.name }
    private let configuration: TranslationServiceConfiguration
    private let credential: @MainActor () throws -> String?
    private let http: TranslationHTTPClient
    private var operation: Task<[String], Error>?
    private var revision = UUID()
    private var nextBaiduRequest = Date.distantPast

    public init(configuration: TranslationServiceConfiguration, session: URLSession? = nil,
                credential: @escaping @MainActor () throws -> String? = { nil }) throws {
        self.configuration = try configuration.validated()
        guard [.deepL, .baidu, .youdao].contains(configuration.adapter) else { throw ServiceConfigurationFailure.unsupportedAdapter }
        self.credential = credential; http = TranslationHTTPClient(session: session)
    }
    deinit { operation?.cancel() }
    public func translate(_ request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> String {
        _ = try LanguageDetection.source(for: request)
        let document = TranslationDocument(request.text, preserveCode: request.preserveCode)
        let indices = document.translatableIndices
        let values = try await translateSegments(indices.map { document.segments[$0].text }, for: request, progress: progress)
        return try document.assemble(Dictionary(uniqueKeysWithValues: zip(indices, values)))
    }
    public func translateSegments(_ texts: [String], for request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> [String] {
        try Task.checkCancellation()
        cancel()
        let source = try LanguageDetection.source(for: request)
        guard texts.count <= 256 else { throw TranslationFailure.tooLong }
        if texts.isEmpty || source == request.target { return texts }
        if source.isChinese && request.target.isChinese { return try texts.map { try ChineseScript.convert($0, to: request.target, preserveCode: request.preserveCode) } }
        let plan = try ProfessionalTranslationPlan(texts: texts, adapter: configuration.adapter)
        var tracker = TranslationProgressTracker(texts: plan.fragments.map(\.text))
        progress?(tracker.progress)
        guard !plan.fragments.isEmpty else { return texts }
        guard let key = try credential()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw ProfessionalTranslationFailure.missingKey }
        guard !key.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }), key.utf8.count <= 8_192 else { throw RemoteTranslationFailure.key }
        let id = UUID(); revision = id
        let task = Task { @MainActor in
            var values: [String] = []
            while values.count < plan.fragments.count {
                try Task.checkCancellation()
                guard self.revision == id else { throw CancellationError() }
                let start = values.count
                var count = 1
                if self.configuration.adapter == .deepL { count = min(50, plan.fragments.count - start) }
                if self.configuration.adapter == .baidu {
                    var bytes = plan.fragments[start].text.utf8.count
                    var characters = plan.fragments[start].text.utf16.count
                    while start + count < plan.fragments.count, bytes + 1 + plan.fragments[start + count].text.utf8.count <= 5_800,
                          characters + 1 + plan.fragments[start + count].text.utf16.count <= 1_000 {
                        bytes += 1 + plan.fragments[start + count].text.utf8.count
                        characters += 1 + plan.fragments[start + count].text.utf16.count; count += 1
                    }
                    let delay = self.nextBaiduRequest.timeIntervalSinceNow
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    guard self.revision == id else { throw CancellationError() }
                }
                var batch = Array(plan.fragments[start..<(start + count)].map(\.text))
                var networkRequest = try self.makeRequest(batch, source: source, target: request.target, key: key)
                // DeepL limits the encoded body, so account for JSON escaping and options as well as prose.
                if self.configuration.adapter == .deepL {
                    while (networkRequest.httpBody?.count ?? 0) > 125_000, batch.count > 1 {
                        batch.removeLast(); networkRequest = try self.makeRequest(batch, source: source, target: request.target, key: key)
                    }
                    guard (networkRequest.httpBody?.count ?? 0) <= 125_000 else { throw ProfessionalTranslationFailure.segmentTooLong }
                }
                if self.configuration.adapter == .baidu { self.nextBaiduRequest = Date().addingTimeInterval(1.05) }
                let data: Data
                do { data = try await self.http.send(networkRequest) }
                catch RemoteTranslationFailure.status(456) where self.configuration.adapter == .deepL {
                    throw ProfessionalTranslationFailure.service(.deepL, "456")
                }
                try Task.checkCancellation()
                guard self.revision == id else { throw CancellationError() }
                let translations = try self.decode(data, originals: batch)
                // Validate the whole batch before publishing any progress or result.
                guard translations.count == batch.count,
                      translations.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains(where: { $0.isNewline }) }) else {
                    throw ProfessionalTranslationFailure.invalidResponse
                }
                for (offset, value) in translations.enumerated() { _ = try tracker.complete(index: start + offset, translation: value) }
                values += translations
                progress?(tracker.progress)
            }
            return try plan.assemble(values, target: request.target)
        }
        operation = task
        defer { if revision == id { operation = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func cancel() { operation?.cancel(); operation = nil; http.cancel(); revision = UUID() }

    private func makeRequest(_ texts: [String], source: AppLanguage, target: AppLanguage, key: String) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        let from = code(source, target: false), to = code(target, target: true)
        switch configuration.adapter {
        case .deepL:
            var body = configuration.parameters.mapValues(\.foundationValue)
            body["text"] = texts; body["source_lang"] = from; body["target_lang"] = to
            body["preserve_formatting"] = true; body["split_sentences"] = "nonewlines"
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        case .baidu, .youdao:
            let query = texts.joined(separator: "\n"), salt = UUID().uuidString
            var fields = ["q": query, "from": from, "to": to, "salt": salt]
            if configuration.adapter == .baidu {
                fields["appid"] = configuration.appID
                fields["sign"] = TranslationServiceSigning.baidu(appID: configuration.appID, query: query, salt: salt, key: key)
                if case let .number(value) = configuration.parameters["action"] { fields["action"] = String(Int(value)) }
            } else {
                let timestamp = String(Int(Date().timeIntervalSince1970))
                fields["appKey"] = configuration.appID; fields["curtime"] = timestamp; fields["signType"] = "v3"; fields["strict"] = "true"
                fields["sign"] = TranslationServiceSigning.youdao(appID: configuration.appID, query: query, salt: salt, timestamp: timestamp, key: key)
                for (name, value) in configuration.parameters { if case let .string(text) = value { fields[name] = text } }
            }
            request.httpBody = TranslationServiceSigning.form(fields)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        case .openAICompatible, .customHTTP: throw ServiceConfigurationFailure.unsupportedAdapter
        }
        return request
    }
    private func decode(_ data: Data, originals: [String]) throws -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProfessionalTranslationFailure.invalidResponse }
        switch configuration.adapter {
        case .deepL:
            guard let rows = json["translations"] as? [[String: Any]], rows.count == originals.count,
                  rows.allSatisfy({ $0["text"] is String }) else { throw ProfessionalTranslationFailure.invalidResponse }
            return rows.map { $0["text"] as! String }
        case .baidu:
            if let code = json["error_code"], String(describing: code) != "52000" { throw ProfessionalTranslationFailure.service(.baidu, String(describing: code)) }
            guard let rows = json["trans_result"] as? [[String: Any]], rows.count == originals.count else { throw ProfessionalTranslationFailure.invalidResponse }
            return try rows.enumerated().map { index, row in
                guard let source = row["src"] as? String, source == originals[index], let value = row["dst"] as? String else { throw ProfessionalTranslationFailure.invalidResponse }
                return value
            }
        case .youdao:
            guard let code = json["errorCode"] else { throw ProfessionalTranslationFailure.invalidResponse }
            guard String(describing: code) == "0" else { throw ProfessionalTranslationFailure.service(.youdao, String(describing: code)) }
            guard let values = json["translation"] as? [String], values.count == 1, originals.count == 1 else { throw ProfessionalTranslationFailure.invalidResponse }
            if let query = json["query"] as? String, query != originals[0] { throw ProfessionalTranslationFailure.invalidResponse }
            return values
        case .openAICompatible, .customHTTP: throw ServiceConfigurationFailure.unsupportedAdapter
        }
    }
    private func code(_ language: AppLanguage, target: Bool) -> String {
        switch configuration.adapter {
        case .deepL:
            if language.isChinese { return target ? (language == .traditionalChinese ? "ZH-HANT" : "ZH-HANS") : "ZH" }
            if language == .portuguese { return target ? "PT-BR" : "PT" }
            return language.rawValue.uppercased()
        case .baidu:
            return [.simplifiedChinese: "zh", .traditionalChinese: "cht", .japanese: "jp", .korean: "kor", .french: "fra", .spanish: "spa", .arabic: "ara", .portuguese: "pt"][language] ?? language.rawValue
        case .youdao:
            return [.simplifiedChinese: "zh-CHS", .traditionalChinese: "zh-CHT", .portuguese: "pt"][language] ?? language.rawValue
        case .openAICompatible, .customHTTP: return language.rawValue
        }
    }
}

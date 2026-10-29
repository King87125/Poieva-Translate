import Foundation

public enum HTTPTranslationFailure: LocalizedError {
    case invalidResponse, service(String), language(AppLanguage)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return L10n.tr("接口返回的译文字段、状态或段落格式不正确，请检查模板。")
        case let .service(message): return message
        case let .language(language): return L10n.tr("此接口模板未配置「\(language.name)」的语言代码。")
        }
    }
}

@MainActor
public final class HTTPTranslationProvider: TranslationProvider {
    public var name: String { configuration.name }
    private let configuration: TranslationServiceConfiguration
    private let template: HTTPTranslationTemplate
    private let credential: @MainActor () throws -> String?
    private let http: TranslationHTTPClient
    private var operation: Task<[String], Error>?
    private var revision = UUID()

    public init(configuration: TranslationServiceConfiguration, session: URLSession? = nil,
                credential: @escaping @MainActor () throws -> String? = { nil }) throws {
        let validated = try configuration.validated()
        guard validated.adapter == .customHTTP, let template = validated.http else { throw ServiceConfigurationFailure.unsupportedAdapter }
        self.configuration = validated; self.template = template; self.credential = credential
        http = TranslationHTTPClient(session: session)
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
        guard texts.count <= 256, texts.reduce(0, { $0 + $1.count }) <= 20_000 else { throw TranslationFailure.tooLong }
        if texts.isEmpty || source == request.target { return texts }
        if source.isChinese && request.target.isChinese {
            return try texts.map { try ChineseScript.convert($0, to: request.target, preserveCode: request.preserveCode) }
        }
        let plan = try ProfessionalTranslationPlan(texts: texts, adapter: .customHTTP, maximumUnits: template.maxCharacters)
        var tracker = TranslationProgressTracker(texts: plan.fragments.map(\.text))
        progress?(tracker.progress)
        guard let first = plan.fragments.first else { return texts }
        // Fail missing language mappings before reading credentials or making any request.
        _ = try template.render(text: first.text, source: source, target: request.target, parameters: configuration.parameters)
        var key: String?
        if template.authentication != .none {
            key = try credential()?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = key, !value.isEmpty else { throw ProfessionalTranslationFailure.missingKey }
            guard value.utf8.count <= 8_192, value.allSatisfy({ !$0.isNewline && !($0.isASCII && ($0.asciiValue ?? 0) < 32) }) else { throw RemoteTranslationFailure.key }
        }
        let id = UUID(); revision = id
        let task = Task { @MainActor in
            var translations: [String] = []
            for (index, fragment) in plan.fragments.enumerated() {
                try Task.checkCancellation()
                guard self.revision == id else { throw CancellationError() }
                var networkRequest = URLRequest(url: self.configuration.endpoint)
                networkRequest.httpMethod = "POST"
                networkRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                networkRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                if let key {
                    switch self.template.authentication {
                    case .bearer: networkRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    case .header: networkRequest.setValue(self.template.keyPrefix + key, forHTTPHeaderField: self.template.keyHeader)
                    case .none: break
                    }
                }
                let body = try self.template.render(text: fragment.text, source: source, target: request.target, parameters: self.configuration.parameters)
                networkRequest.httpBody = try JSONEncoder().encode(body)
                guard (networkRequest.httpBody?.count ?? 0) <= 262_144 else { throw TranslationFailure.tooLong }
                let data: Data
                do { data = try await self.http.send(networkRequest) }
                catch let RemoteTranslationFailure.status(code) {
                    throw HTTPTranslationFailure.service(self.template.errorMessages[String(code)] ?? RemoteTranslationFailure.status(code).localizedDescription)
                }
                try Task.checkCancellation()
                guard self.revision == id else { throw CancellationError() }
                let json: ServiceJSONValue
                do { json = try JSONDecoder().decode(ServiceJSONValue.self, from: data) }
                catch { throw HTTPTranslationFailure.invalidResponse }
                if !self.template.successPath.isEmpty {
                    guard let value = HTTPTranslationTemplate.field(self.template.successPath, in: json) else { throw HTTPTranslationFailure.invalidResponse }
                    if value != self.template.successValue {
                        let code: String?
                        switch value {
                        case let .string(string): code = string
                        case let .number(number): code = number.isFinite && number >= -1_000_000 && number <= 1_000_000 && number.rounded() == number ? String(Int(number)) : nil
                        case let .bool(boolean): code = String(boolean)
                        default: code = nil
                        }
                        throw HTTPTranslationFailure.service(code.flatMap { self.template.errorMessages[$0] } ?? L10n.tr("接口未返回成功状态，请检查模板、密钥或服务账户。"))
                    }
                }
                guard case let .string(text) = HTTPTranslationTemplate.field(self.template.responsePath, in: json),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains(where: { $0.isNewline }) else {
                    throw HTTPTranslationFailure.invalidResponse
                }
                _ = try tracker.complete(index: index, translation: text)
                translations.append(text); progress?(tracker.progress)
            }
            return try plan.assemble(translations, target: request.target)
        }
        operation = task
        defer { if revision == id { operation = nil } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func cancel() { operation?.cancel(); operation = nil; http.cancel(); revision = UUID() }
}

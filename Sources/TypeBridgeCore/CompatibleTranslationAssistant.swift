import Foundation

@MainActor
public final class CompatibleTranslationAssistant: TranslationAssistant {
    public var name: String { configuration.name }
    private let configuration: TranslationServiceConfiguration
    private let credential: @MainActor () throws -> String?
    private let http: TranslationHTTPClient
    public init(configuration: TranslationServiceConfiguration, session: URLSession? = nil,
                credential: @escaping @MainActor () throws -> String? = { nil }) throws {
        self.configuration = try configuration.validated()
        guard configuration.adapter == .openAICompatible else { throw ServiceConfigurationFailure.unsupportedAdapter }
        self.credential = credential; http = TranslationHTTPClient(session: session)
    }
    public func refine(_ request: TranslationRefinementRequest) async throws -> [String] {
        try Task.checkCancellation()
        let payload = try request.payload()
        var body = configuration.parameters.mapValues(\.foundationValue)
        body["model"] = configuration.model; body["stream"] = false; body["store"] = false
        if body["max_tokens"] == nil && body["max_completion_tokens"] == nil { body["max_tokens"] = 4096 }
        body["messages"] = [["role": "system", "content": TranslationRefinementRequest.instructions], ["role": "user", "content": payload]]
        if configuration.jsonMode { body["response_format"] = ["type": "json_object"] }
        var network = URLRequest(url: configuration.endpoint)
        network.httpMethod = "POST"; network.timeoutInterval = 15
        network.setValue("application/json", forHTTPHeaderField: "Content-Type")
        network.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = try credential(), !key.isEmpty {
            guard !key.contains(where: { $0.isNewline || $0 == "\0" }) else { throw RemoteTranslationFailure.key }
            network.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        network.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data = try await http.send(network)
        struct Envelope: Decodable {
            struct Choice: Decodable { struct Message: Decodable { var content: String?; var refusal: String? }; var message: Message; var finish_reason: String? }
            var choices: [Choice]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.choices.count == 1,
              let choice = envelope.choices.first, choice.finish_reason == nil || choice.finish_reason == "stop",
              choice.message.refusal == nil, let content = choice.message.content else { throw TranslationAssistanceFailure.invalidResponse }
        return try request.decode(content)
    }
    public func cancel() { http.cancel() }
}

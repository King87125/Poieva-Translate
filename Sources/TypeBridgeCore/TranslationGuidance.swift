import Foundation

/// Reference text is bounded, read-only and never part of the replacement range.
public struct TranslationContext: Codable, Equatable, Sendable {
    public static let maximumCharactersPerSide = 600
    public let before: String
    public let after: String
    public var isEmpty: Bool { before.isEmpty && after.isEmpty }

    public init(before: String = "", after: String = "") {
        let before = String(before.suffix(Self.maximumCharactersPerSide))
        let after = String(after.prefix(Self.maximumCharactersPerSide))
        self.before = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : before
        self.after = after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : after
    }

    /// AX ranges are UTF-16 offsets. Never guess a selection by searching for repeated text.
    public static func capture(in text: String, selection: TextSelection, expected: String) -> Self? {
        guard selection.location >= 0, selection.length > 0,
              selection.location <= text.utf16.count,
              selection.length <= text.utf16.count - selection.location,
              let range = Range(NSRange(location: selection.location, length: selection.length), in: text),
              String(text[range]) == expected else { return nil }
        return Self(before: String(text[..<range.lowerBound].suffix(maximumCharactersPerSide)),
                    after: String(text[range.upperBound...].prefix(maximumCharactersPerSide)))
    }
}

public enum TranslationTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, natural, concise, formal, conversational
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .original: return L10n.tr("沿用原文")
        case .natural: return L10n.tr("自然")
        case .concise: return L10n.tr("简洁")
        case .formal: return L10n.tr("正式")
        case .conversational: return L10n.tr("口语")
        }
    }
}

public struct TranslationTerm: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: String
    public var translation: String
    public var target: AppLanguage
    public init(id: UUID = UUID(), source: String = "", translation: String = "", target: AppLanguage = .automatic) {
        self.id = id; self.source = source; self.translation = translation; self.target = target
    }
}

public struct TranslationPreferences: Codable, Equatable, Sendable {
    public var tone: TranslationTone
    public var instructions: String
    public var target: AppLanguage
    public var terms: [TranslationTerm]
    public init(tone: TranslationTone = .original, instructions: String = "", target: AppLanguage = .automatic,
                terms: [TranslationTerm] = []) {
        self.tone = tone; self.instructions = instructions; self.target = target; self.terms = terms
    }
    public var isEmpty: Bool { tone == .original && instructions.isEmpty && terms.isEmpty }

    public func validated() throws -> Self {
        var copy = self
        copy.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard copy.instructions.count <= 8_192, terms.count <= 64,
              Set(terms.map(\.id)).count == terms.count else { throw TranslationAssistanceFailure.invalidPreferences }
        copy.terms = try terms.map { term in
            var term = term
            term.source = term.source.trimmingCharacters(in: .whitespacesAndNewlines)
            term.translation = term.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.source.isEmpty, !term.translation.isEmpty, term.source.count <= 80,
                  term.translation.count <= 200, !term.source.contains(where: { $0.isNewline }),
                  !term.translation.contains(where: { $0.isNewline }) else { throw TranslationAssistanceFailure.invalidPreferences }
            return term
        }
        let keys = copy.terms.map { $0.target.rawValue + ":" + $0.source.lowercased() }
        guard Set(keys).count == keys.count else { throw TranslationAssistanceFailure.invalidPreferences }
        return copy
    }

    /// Retrieve only applicable preferences; unrelated terminology never enters the prompt.
    public func relevant(to texts: [String], target language: AppLanguage) -> Self {
        let applies = target == .automatic || target == language
        let matches = terms.filter { term in
            (term.target == .automatic || term.target == language) &&
            texts.contains { $0.range(of: term.source, options: [.caseInsensitive]) != nil }
        }
        let specific = Set(matches.filter { $0.target == language }.map { $0.source.lowercased() })
        let terms = matches.filter { $0.target == language || !specific.contains($0.source.lowercased()) }
        return Self(tone: applies ? tone : .original, instructions: applies ? instructions : "", target: language, terms: terms)
    }
}

public struct TranslationGuidance: Codable, Equatable, Sendable {
    public var context: TranslationContext
    public var preferences: TranslationPreferences
    public var profile: TranslationProfileSnapshot?
    public init(context: TranslationContext = .init(), preferences: TranslationPreferences = .init(), profile: TranslationProfileSnapshot? = nil) {
        self.context = context; self.preferences = preferences; self.profile = profile
    }
    public var isEmpty: Bool { context.isEmpty && preferences.isEmpty && profile == nil }
    public func resolved(for texts: [String], target: AppLanguage, source: AppLanguage = .automatic) throws -> Self? {
        let preferences = try profile?.preferences(for: texts, source: source, target: target) ?? preferences.validated()
        let result = Self(context: .init(before: context.before, after: context.after),
                          preferences: preferences.relevant(to: texts, target: target))
        return result.isEmpty ? nil : result
    }
    public var promptValue: ServiceJSONValue {
        .object([
            "before": .string(context.before), "after": .string(context.after),
            "style": .string(preferences.tone.rawValue), "preferences": .string(preferences.instructions),
            "terminology": .array(preferences.terms.map { .object(["source": .string($0.source), "translation": .string($0.translation)]) })
        ])
    }
}

public enum TranslationAssistanceFailure: LocalizedError {
    case invalidPreferences, unavailable(String), tooLong, invalidResponse, changedFacts, changedPerspective
    public var errorDescription: String? {
        switch self {
        case .invalidPreferences: return L10n.tr("规则最多 8,192 字，单次最多 64 条术语；原文最多 80 字，固定译法最多 200 字，同一语言的术语不能重复。")
        case let .unavailable(reason): return reason
        case .tooLong: return L10n.tr("辅助模型适合短段落，请缩小选区，或在翻译偏好中关闭辅助模型。")
        case .invalidResponse: return L10n.tr("辅助模型的结果不完整，未替换原文，请重试或更换辅助模型。")
        case .changedFacts: return L10n.tr("辅助模型改变了数字或受保护内容，未替换原文，请重试。")
        case .changedPerspective: return L10n.tr("模型改变了原文明写的人称，未替换原文，请重试或更换模型。")
        }
    }
}

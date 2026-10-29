import Foundation
import NaturalLanguage

public enum LanguageDetection {
    public static func source(for request: TranslationRequest) throws -> AppLanguage {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationFailure.emptyText }
        guard request.text.count <= 20_000 else { throw TranslationFailure.tooLong }
        if request.source != .automatic { return request.source }
        let document = TranslationDocument(request.text, preserveCode: request.preserveCode)
        let prose = document.translatableIndices.map { document.segments[$0].text }.joined(separator: " ")
        if prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return request.target }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let language = recognizer.dominantLanguage,
              let detected = AppLanguage.detected(language.rawValue) else { throw TranslationFailure.detectionFailed }
        guard detected.isChinese else { return detected }

        // Shared characters such as 你好 cannot establish a Chinese script. Prefer
        // Simplified Chinese for ambiguous text instead of trusting a noisy short-text guess.
        let simplified = prose.applyingTransform(StringTransform("Hant-Hans"), reverse: false)
        if let simplified, simplified != prose { return .traditionalChinese }
        return .simplifiedChinese
    }
}

public enum ChineseScript {
    /// Script conversion is local text processing, not an Apple translation language pair.
    public static func convert(_ text: String, to target: AppLanguage, preserveCode: Bool) throws -> String {
        guard target.isChinese else { throw TranslationFailure.incompleteResponse }
        let transform = StringTransform(target == .simplifiedChinese ? "Hant-Hans" : "Hans-Hant")
        let document = TranslationDocument(text, preserveCode: preserveCode)
        var converted: [Int: String] = [:]
        for index in document.translatableIndices {
            guard let value = document.segments[index].text.applyingTransform(transform, reverse: false) else {
                throw TranslationFailure.incompleteResponse
            }
            converted[index] = value
        }
        return try document.assemble(converted)
    }
}

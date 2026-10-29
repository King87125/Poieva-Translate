import Foundation

public enum TranslationDirection: String, CaseIterable, Codable, Identifiable, Sendable {
    case chineseEnglish
    case fixedTarget

    public var id: String { rawValue }
    public var name: String { self == .chineseEnglish ? L10n.tr("中英自动互译") : L10n.tr("指定目标语言") }

    public func targetLabel(_ fixedTarget: AppLanguage) -> String {
        self == .chineseEnglish ? name : fixedTarget.name
    }

    /// Resolve once per operation, using the selected passage rather than surrounding text.
    public func request(text: String, source: AppLanguage = .automatic,
                        fixedTarget: AppLanguage, preserveCode: Bool) throws -> TranslationRequest {
        var request = TranslationRequest(text: text, source: source, target: fixedTarget, preserveCode: preserveCode)
        guard self == .chineseEnglish else { return request }
        let detected = try LanguageDetection.source(for: request)
        request.source = detected
        // A protected code/URL-only input has no prose to translate in either direction.
        if TranslationDocument(text, preserveCode: preserveCode).translatableIndices.isEmpty {
            request.target = detected
        } else if detected.isChinese {
            request.target = .english
        } else if detected == .english {
            request.target = .simplifiedChinese
        } else {
            throw TranslationFailure.outsideBilingualPair(detected)
        }
        return request
    }
}

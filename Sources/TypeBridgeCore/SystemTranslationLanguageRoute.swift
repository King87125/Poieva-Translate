import Foundation

public enum SystemTranslationLanguageSupport: Sendable {
    case ready, notInstalled, temporarilyUnavailable, unsupported
}

/// Chinese scripts can share an installed model through local conversion.
/// The original request and document stay intact; only model input/output change.
public struct SystemTranslationLanguageRoute: Hashable, Sendable {
    public let requestedSource: AppLanguage
    public let requestedTarget: AppLanguage
    public let source: AppLanguage
    public let target: AppLanguage

    public static func resolve(source: AppLanguage, target: AppLanguage,
                               support: (SystemTranslationLanguageRoute) async throws -> SystemTranslationLanguageSupport) async throws -> Self {
        let exact = Self(requestedSource: source, requestedTarget: target, source: source, target: target)
        var candidates = [exact]
        if source.isChinese && !target.isChinese {
            candidates.append(Self(requestedSource: source, requestedTarget: target,
                source: source == .traditionalChinese ? .simplifiedChinese : .traditionalChinese, target: target))
        } else if target.isChinese && !source.isChinese {
            candidates.append(Self(requestedSource: source, requestedTarget: target, source: source,
                target: target == .traditionalChinese ? .simplifiedChinese : .traditionalChinese))
        }
        var missing: Self?, temporarilyUnavailable = false
        for candidate in candidates {
            try Task.checkCancellation()
            let status = try await support(candidate)
            try Task.checkCancellation()
            switch status {
            case .ready: return candidate
            case .notInstalled: if missing == nil { missing = candidate }
            case .temporarilyUnavailable: temporarilyUnavailable = true
            case .unsupported: break
            }
        }
        // An installed but warming/unavailable model must not become a download request.
        if temporarilyUnavailable { throw TranslationFailure.systemNotReady }
        if let missing { throw TranslationFailure.needsLanguagePack(missing.source, missing.target) }
        throw TranslationFailure.unsupportedLanguage(source, target)
    }

    public func prepare(_ texts: [String], preserveCode: Bool) throws -> [String] {
        guard source != requestedSource, source.isChinese, requestedSource.isChinese else { return texts }
        return try texts.map { try ChineseScript.convert($0, to: source, preserveCode: preserveCode) }
    }

    public func finish(_ text: String, preserveCode: Bool) throws -> String {
        guard target != requestedTarget, target.isChinese, requestedTarget.isChinese else { return text }
        return try ChineseScript.convert(text, to: requestedTarget, preserveCode: preserveCode)
    }
}

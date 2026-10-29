import Foundation

/// Conservative hints for explicit first-person actors. Ambiguous/possessive
/// phrases are left to the model; this is not a general grammar parser.
public enum SourcePersonConstraint: String, Sendable {
    case singular = "first_person_singular"
    case plural = "first_person_plural"

    public static func detect(in text: String, source: AppLanguage, target: AppLanguage) -> Self? {
        let pattern: String
        if source.isChinese && target == .english {
            pattern = #"(?:^|[，。！？；：、\s“”‘’「」『』（）()])(我(?:们|們)?)(?=\s*(?:还|還|仍|已|正|将|將|会|會|要|想|能|愿|願|也|都|就|很|不|没|沒|是|在|有|去|回|来|來|说|說|看|做|给|給|把|被|让|讓|需要|希望|准备|準備|计划|計劃|负责|負責|今天|明天|昨天|本周|这周|這周))"#
        } else if source == .english && target.isChinese {
            pattern = #"(?i)\b(I|we)\s+(?=(?:am|are|was|were|have|had|will|would|can|could|should|must|did|do|went|go|returned|return|need|want|think|agree|hope|plan|reviewed|confirmed)\b)"#
        } else { return nil }
        let regex = try! NSRegularExpression(pattern: pattern)
        let values = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Self? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return ["我们", "我們", "we"].contains(String(text[range]).lowercased()) ? .plural : .singular
        })
        // Mixed perspectives need semantic interpretation, not a single-person hint.
        return values.count == 1 ? values.first : nil
    }

    public func isPresent(in translation: String, target: AppLanguage) -> Bool {
        if target == .english {
            let pattern = self == .singular ? #"(?i)\b(?:I|me|my|mine|myself)\b"# : #"(?i)\b(?:we|us|our|ours|ourselves)\b"#
            return translation.range(of: pattern, options: .regularExpression) != nil
        }
        if target.isChinese {
            let pattern = self == .singular ? #"我(?!们|們|国|國|司|方|校|院|厂|廠|军|軍)"# : #"我们|我們"#
            return translation.range(of: pattern, options: .regularExpression) != nil
        }
        return true
    }

    public static func validate(original: String, translation: String, source: AppLanguage, target: AppLanguage) throws {
        if let constraint = detect(in: original, source: source, target: target), !constraint.isPresent(in: translation, target: target) {
            throw TranslationAssistanceFailure.changedPerspective
        }
    }
}

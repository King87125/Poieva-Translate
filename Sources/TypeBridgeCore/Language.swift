import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "auto"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt-BR"
    case russian = "ru"
    case arabic = "ar"

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .automatic: return L10n.tr("自动检测")
        case .simplifiedChinese: return L10n.tr("简体中文")
        case .traditionalChinese: return L10n.tr("繁体中文")
        case .english: return L10n.tr("英文")
        case .japanese: return L10n.tr("日文")
        case .korean: return L10n.tr("韩文")
        case .french: return L10n.tr("法文")
        case .german: return L10n.tr("德文")
        case .spanish: return L10n.tr("西班牙文")
        case .italian: return L10n.tr("意大利文")
        case .portuguese: return L10n.tr("葡萄牙文")
        case .russian: return L10n.tr("俄文")
        case .arabic: return L10n.tr("阿拉伯文")
        }
    }

    public static var targets: [Self] { allCases.filter { $0 != .automatic } }
    /// Model instructions must not depend on the language of the app's UI.
    public var promptName: String {
        switch self {
        case .automatic: return "auto"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        default: return Locale(identifier: "en").localizedString(forIdentifier: rawValue) ?? rawValue
        }
    }
    public var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }

    public static func detected(_ identifier: String) -> Self? {
        if let exact = Self(rawValue: identifier) { return exact }
        if identifier.hasPrefix("zh-Hant") { return .traditionalChinese }
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("pt") { return .portuguese }
        return targets.first { identifier == $0.rawValue || identifier.hasPrefix($0.rawValue + "-") }
    }
}

public struct TranslationRequest: Sendable {
    public var text: String
    public var source: AppLanguage
    public var target: AppLanguage
    public var preserveCode: Bool
    public var guidance: TranslationGuidance?

    public init(text: String, source: AppLanguage = .automatic, target: AppLanguage, preserveCode: Bool = true,
                guidance: TranslationGuidance? = nil) {
        self.text = text
        self.source = source
        self.target = target
        self.preserveCode = preserveCode
        self.guidance = guidance
    }
}

public enum TranslationFailure: LocalizedError {
    case emptyText
    case tooLong
    case detectionFailed
    case outsideBilingualPair(AppLanguage)
    case unsupportedLanguage(AppLanguage, AppLanguage)
    case needsLanguagePack(AppLanguage, AppLanguage)
    case incompleteResponse
    case systemUnavailable
    case systemNotReady

    public var errorDescription: String? {
        switch self {
        case .emptyText: return L10n.tr("还没有要翻译的文字。")
        case .tooLong: return L10n.tr("这段文字超过 20,000 字，请分段翻译。")
        case .detectionFailed: return L10n.tr("无法识别原文语言，请在翻译窗口中手动选择。")
        case let .outsideBilingualPair(source): return L10n.tr("识别到\(source.name)，请在设置中切换为「指定目标语言」。")
        case let .unsupportedLanguage(source, target): return L10n.tr("系统翻译暂不支持「\(source.name) → \(target.name)」，请更换目标语言。")
        case let .needsLanguagePack(source, target):
            return L10n.tr("首次使用「\(source.name) → \(target.name)」需要先准备系统语言包。")
        case .incompleteResponse: return L10n.tr("翻译结果不完整，原文已保留，请重试。")
        case .systemUnavailable: return L10n.tr("系统翻译暂时不可用，请稍后重试。")
        case .systemNotReady: return L10n.tr("语言包已安装，但系统翻译暂未就绪，请稍后重试。")
        }
    }
}

@MainActor
public protocol TranslationProvider {
    var name: String { get }
    var supportsGuidance: Bool { get }
    var executionInfo: TranslationExecutionInfo? { get }
    func translate(_ request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> String
    func translateSegments(_ texts: [String], for request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> [String]
    func cancel()
}

public extension TranslationProvider {
    var supportsGuidance: Bool { false }
    var executionInfo: TranslationExecutionInfo? { nil }
    func translate(_ request: TranslationRequest) async throws -> String {
        try await translate(request, progress: nil)
    }
    func translateSegments(_ texts: [String], for request: TranslationRequest) async throws -> [String] {
        try await translateSegments(texts, for: request, progress: nil)
    }
}

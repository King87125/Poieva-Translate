import AppKit
import TypeBridgeCore

enum FeedbackPhase: Equatable {
    case reading, translating, replacing, success, cancelled, failure, info
    var isActive: Bool { self == .reading || self == .translating || self == .replacing }
    var showsFeedback: Bool { isActive || self == .failure }
}

enum FeedbackSurface { case workbench, floating, selection }
enum FeedbackRecovery {
    case retry, settings, languagePacks, workbench, preservedTranslation
    var title: String {
        switch self {
        case .retry: return L10n.tr("重试")
        case .settings: return L10n.tr("打开设置")
        case .languagePacks: return L10n.tr("下载语言包")
        case .workbench: return L10n.tr("打开翻译")
        case .preservedTranslation: return L10n.tr("查看译文")
        }
    }
}

struct TranslationFeedback {
    let id: UUID
    var phase: FeedbackPhase
    var surface: FeedbackSurface
    var title: String
    var detail = ""
    var progress: TranslationProgress?
    var recovery: FeedbackRecovery?
    var anchor: CGRect?
    var isPreview = false
    let startedAt = Date()
}

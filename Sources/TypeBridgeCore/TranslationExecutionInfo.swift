import Foundation

/// Last-run metadata only. Never contains source text, model output or credentials.
public struct TranslationExecutionInfo: Equatable, Sendable {
    public enum Route: Equatable, Sendable { case basic, directAI, assisted }
    public let route: Route
    public let beforeCharacters: Int
    public let afterCharacters: Int
    public let usedPreferences: Bool
    public let assistantName: String?
    public var hasContext: Bool { beforeCharacters > 0 || afterCharacters > 0 }
    public var usedContext: Bool { hasContext && route != .basic }

    public init(route: Route, guidance: TranslationGuidance?, assistantName: String? = nil) {
        self.route = route
        beforeCharacters = guidance?.context.before.count ?? 0
        afterCharacters = guidance?.context.after.count ?? 0
        usedPreferences = route != .basic && guidance?.preferences.isEmpty == false
        self.assistantName = assistantName
    }
    public var routeLabel: String {
        switch route {
        case .basic: return L10n.tr("基础翻译")
        case .directAI: return L10n.tr("AI 翻译")
        case .assisted: return L10n.tr("AI 辅助")
        }
    }
    public var caption: String {
        let reference: String
        if usedContext { reference = L10n.tr("已传入前后文") }
        else if hasContext { reference = L10n.tr("前后文未应用") }
        else if usedPreferences { reference = L10n.tr("已应用个人偏好") }
        else { reference = "" }
        return [reference, routeLabel].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    public var detail: String {
        let counts = L10n.tr("前文 \(beforeCharacters) 字，后文 \(afterCharacters) 字。")
        return counts + (assistantName.map { L10n.tr("辅助模型：\($0)。") } ?? "")
    }
}

import Foundation

public enum CaptionInputChannel: String, Sendable, Hashable { case system, microphone }

public enum CaptionAudioInput: String, Codable, CaseIterable, Sendable {
    case microphone, system, both
    public var name: String {
        switch self {
        case .microphone: return L10n.tr("仅麦克风")
        case .system: return L10n.tr("仅系统声音")
        case .both: return L10n.tr("系统声音和麦克风")
        }
    }
    public var channels: [CaptionInputChannel] {
        switch self { case .microphone: return [.microphone]; case .system: return [.system]; case .both: return [.system, .microphone] }
    }
    public func channels(isFile: Bool) -> [CaptionInputChannel] { isFile ? [.system] : channels }
    /// Upgrades never carry the old additive checkbox into two billable streams.
    /// Both inputs require a new explicit selection in the source picker.
    public static func migrated(raw: String?, legacyMicrophone: Bool) -> Self {
        if let raw, let selected = Self(rawValue: raw) { return selected }
        return legacyMicrophone ? .microphone : .system
    }
}

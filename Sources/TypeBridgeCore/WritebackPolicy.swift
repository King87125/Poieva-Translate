import Foundation

public struct TextSelection: Equatable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct WritebackState: Sendable {
    public var processID: Int32
    public var hasSameFocus: Bool
    public var text: String?
    public var selection: TextSelection?

    public init(processID: Int32, hasSameFocus: Bool, text: String?, selection: TextSelection?) {
        self.processID = processID
        self.hasSameFocus = hasSameFocus
        self.text = text
        self.selection = selection
    }
}

public enum WritebackPolicy {
    /// An unverifiable target is a refusal, never permission to paste into the current focus.
    public static func refusal(original: WritebackState, current: WritebackState) -> String? {
        guard original.processID == current.processID, current.hasSameFocus else {
            return L10n.tr("输入位置已改变，未自动替换。")
        }
        guard let before = original.text, let after = current.text, before == after else {
            return L10n.tr("原文已经修改，未覆盖新内容。")
        }
        guard original.selection == current.selection else {
            return L10n.tr("光标或选区已改变，未自动替换。")
        }
        return nil
    }
}

import Foundation

public enum InputTranslationScope: Equatable, Sendable {
    case wholeInput
    case selection
}

public enum SelectionWritebackPlan: Equatable, Sendable {
    case refuse(String)
    case replace(expectedFullText: String?)
}

public enum InputTranslationPolicy {
    public static func selectionWritebackPlan(original: WritebackState, current: WritebackState,
                                              editorText: String?, translation: String) -> SelectionWritebackPlan {
        if let refusal = WritebackPolicy.refusal(original: original, current: current) { return .refuse(refusal) }
        guard let source = current.text, isConsistentSelection(source, range: current.selection) else {
            return .refuse(L10n.tr("无法确认选中文字的范围，译文已保留，没有自动回填。"))
        }
        // An editor's AXValue and its document-wide selection can use different
        // coordinate spaces. A missing whole-editor baseline is not a text change.
        let expected = current.selection.flatMap { range in
            editorText.flatMap { replacingSelection(in: $0, range: range, source: source, translation: translation) }
        }
        return .replace(expectedFullText: expected)
    }

    public static func scope(selectedText: String?, selectedRange: TextSelection?) -> InputTranslationScope {
        if let selectedText, !selectedText.isEmpty { return .selection }
        if let selectedRange, selectedRange.length > 0 { return .selection }
        return .wholeInput
    }

    public static func isConsistentSelection(_ text: String, range: TextSelection?) -> Bool {
        guard !text.isEmpty else { return false }
        guard let range else { return true }
        return range.location >= 0 && range.length > 0 && range.length == text.utf16.count
    }

    /// Produce a verification baseline without changing anything outside the user's selection.
    public static func replacingSelection(in fullText: String, range: TextSelection,
                                          source: String, translation: String) -> String? {
        let count = fullText.utf16.count
        guard range.location >= 0, range.length > 0, range.location <= count,
              range.length <= count - range.location,
              let stringRange = Range(NSRange(location: range.location, length: range.length), in: fullText),
              String(fullText[stringRange]) == source else { return nil }
        return fullText.replacingCharacters(in: stringRange, with: translation)
    }
}

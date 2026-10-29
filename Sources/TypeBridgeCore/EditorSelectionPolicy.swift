import Foundation

public enum EditorScope: Sendable {
    case nativeInput
    case webInput
    case documentContainer
}

public enum EditorSelectionPlan: Equatable, Sendable {
    case reuseSelection
    case setLocalRange(TextSelection)
    case keyboardSelectAllOnce
    case requireUserSelection
}

/// Decides how to select a single editor's contents without escalating to a whole document.
public enum EditorSelectionPolicy {
    public static func plan(
        scope: EditorScope,
        textUTF16Length: Int?,
        currentRange: TextSelection?,
        selectionMatchesText: Bool,
        canSetLocalRange: Bool,
        canReadSelectedText: Bool
    ) -> EditorSelectionPlan {
        guard scope != .documentContainer else { return .requireUserSelection }
        if let length = textUTF16Length, length <= 0 { return .requireUserSelection }
        if selectionMatchesText { return .reuseSelection }
        if let length = textUTF16Length, length > 0 {
            let whole = TextSelection(location: 0, length: length)
            if canSetLocalRange { return .setLocalRange(whole) }
            // In block editors, another Select All can expand from this range to the whole page.
            if currentRange == whole { return .reuseSelection }
        }
        if scope == .nativeInput { return .keyboardSelectAllOnce }
        if textUTF16Length != nil, currentRange?.length == 0, canReadSelectedText {
            return .keyboardSelectAllOnce
        }
        return .requireUserSelection
    }

    public static func verifies(
        scope: EditorScope,
        expectedText: String?,
        expectedUTF16Length: Int?,
        selectedText: String?,
        selectedRange: TextSelection?,
        localRangeWasSet: Bool
    ) -> Bool {
        guard scope != .documentContainer else { return false }
        if let selectedText {
            if let expectedText { return selectedText == expectedText }
            if let length = expectedUTF16Length { return selectedText.utf16.count == length }
            return scope == .nativeInput
        }
        if localRangeWasSet, let length = expectedUTF16Length, length > 0,
           selectedRange == TextSelection(location: 0, length: length) { return true }
        return scope == .nativeInput
    }
}

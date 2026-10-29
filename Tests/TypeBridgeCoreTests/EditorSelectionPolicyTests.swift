import Testing
@testable import TypeBridgeCore

struct EditorSelectionPolicyTests {
    @Test func localRangesTakePriorityOverKeyboardShortcuts() {
        #expect(EditorSelectionPolicy.plan(scope: .webInput, textUTF16Length: 2,
            currentRange: TextSelection(location: 2, length: 0), selectionMatchesText: false,
            canSetLocalRange: true, canReadSelectedText: true) == .setLocalRange(TextSelection(location: 0, length: 2)))
    }

    @Test func alreadySelectedBlockNeverReceivesAnotherSelectAll() {
        #expect(EditorSelectionPolicy.plan(scope: .webInput, textUTF16Length: 2,
            currentRange: TextSelection(location: 0, length: 2), selectionMatchesText: false,
            canSetLocalRange: false, canReadSelectedText: true) == .reuseSelection)
    }

    @Test func exactExistingTextSelectionCanBeReused() {
        #expect(EditorSelectionPolicy.plan(scope: .webInput, textUTF16Length: 2,
            currentRange: nil, selectionMatchesText: true,
            canSetLocalRange: false, canReadSelectedText: true) == .reuseSelection)
    }

    @Test func unknownWebScopeRequiresExplicitUserSelection() {
        #expect(EditorSelectionPolicy.plan(scope: .webInput, textUTF16Length: nil,
            currentRange: nil, selectionMatchesText: false,
            canSetLocalRange: false, canReadSelectedText: false) == .requireUserSelection)
    }

    @Test func nativeInputCanUseItsIdempotentSelectAll() {
        #expect(EditorSelectionPolicy.plan(scope: .nativeInput, textUTF16Length: 5,
            currentRange: nil, selectionMatchesText: false,
            canSetLocalRange: false, canReadSelectedText: false) == .keyboardSelectAllOnce)
    }

    @Test func webKeyboardFallbackRequiresACaretAndReadableSelection() {
        #expect(EditorSelectionPolicy.plan(scope: .webInput, textUTF16Length: 5,
            currentRange: TextSelection(location: 3, length: 0), selectionMatchesText: false,
            canSetLocalRange: false, canReadSelectedText: true) == .keyboardSelectAllOnce)
        #expect(EditorSelectionPolicy.plan(scope: .webInput, textUTF16Length: 5,
            currentRange: TextSelection(location: 0, length: 3), selectionMatchesText: false,
            canSetLocalRange: false, canReadSelectedText: true) == .requireUserSelection)
    }

    @Test func pageContainersAreNeverSelectedAsInputs() {
        #expect(EditorSelectionPolicy.plan(scope: .documentContainer, textUTF16Length: 1000,
            currentRange: TextSelection(location: 0, length: 0), selectionMatchesText: true,
            canSetLocalRange: true, canReadSelectedText: true) == .requireUserSelection)
    }

    @Test func expandedWholePageTextFailsVerification() {
        #expect(!EditorSelectionPolicy.verifies(scope: .webInput, expectedText: "你好",
            expectedUTF16Length: 2, selectedText: "标题\n你好\n另一段正文",
            selectedRange: nil, localRangeWasSet: false))
    }

    @Test func matchingLengthDoesNotHideDifferentText() {
        #expect(!EditorSelectionPolicy.verifies(scope: .webInput, expectedText: "你好",
            expectedUTF16Length: 2, selectedText: "再见",
            selectedRange: TextSelection(location: 0, length: 2), localRangeWasSet: true))
    }

    @Test func rangeOnlyVerificationRequiresASuccessfulLocalSetter() {
        let range = TextSelection(location: 0, length: 2)
        #expect(EditorSelectionPolicy.verifies(scope: .webInput, expectedText: "你好",
            expectedUTF16Length: 2, selectedText: nil, selectedRange: range, localRangeWasSet: true))
        #expect(!EditorSelectionPolicy.verifies(scope: .webInput, expectedText: "你好",
            expectedUTF16Length: 2, selectedText: nil, selectedRange: range, localRangeWasSet: false))
    }

    @Test func emojiUsesTheEditorsUTF16RangeUnits() {
        let text = "你好👋"
        #expect(text.utf16.count == 4)
        #expect(EditorSelectionPolicy.plan(scope: .webInput, textUTF16Length: text.utf16.count,
            currentRange: nil, selectionMatchesText: false, canSetLocalRange: true,
            canReadSelectedText: false) == .setLocalRange(TextSelection(location: 0, length: 4)))
    }
}

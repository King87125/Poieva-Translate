import Testing
@testable import TypeBridgeCore

struct InputTranslationPolicyTests {
    @Test func caretWithoutSelectionTranslatesWholeInput() {
        #expect(InputTranslationPolicy.scope(selectedText: "", selectedRange: TextSelection(location: 4, length: 0)) == .wholeInput)
        #expect(InputTranslationPolicy.scope(selectedText: nil, selectedRange: nil) == .wholeInput)
    }

    @Test func rangeWithoutReadableTextStillMeansSelection() {
        #expect(InputTranslationPolicy.scope(selectedText: nil, selectedRange: TextSelection(location: 2, length: 5)) == .selection)
    }

    @Test func selectedTextWithoutARangeNeverFallsBackToWholeInput() {
        #expect(InputTranslationPolicy.scope(selectedText: "你好", selectedRange: nil) == .selection)
        #expect(InputTranslationPolicy.isConsistentSelection("你好", range: nil))
    }

    @Test func inconsistentSelectionCannotReplaceWholeInput() {
        #expect(!InputTranslationPolicy.isConsistentSelection("你好", range: TextSelection(location: 0, length: 0)))
        #expect(!InputTranslationPolicy.isConsistentSelection("你好", range: TextSelection(location: 0, length: 3)))
        #expect(!InputTranslationPolicy.isConsistentSelection("", range: nil))
    }

    @Test func partialTranslationPreservesBothSidesAndNewlines() {
        let original = "开头不变\n你好，世界\n结尾不变"
        let result = InputTranslationPolicy.replacingSelection(in: original,
            range: TextSelection(location: 5, length: 5), source: "你好，世界", translation: "Hello, world")
        #expect(result == "开头不变\nHello, world\n结尾不变")
    }

    @Test func reverseTranslationAlsoPreservesSurroundingText() {
        #expect(InputTranslationPolicy.replacingSelection(in: "Before: Hello! After.",
            range: TextSelection(location: 8, length: 5), source: "Hello", translation: "你好") == "Before: 你好! After.")
    }

    @Test func emojiRangesUseUTF16Units() {
        #expect(InputTranslationPolicy.isConsistentSelection("你好👋", range: TextSelection(location: 2, length: 4)))
        #expect(InputTranslationPolicy.replacingSelection(in: "👋你好👋!",
            range: TextSelection(location: 2, length: 4), source: "你好👋", translation: "Hello👋") == "👋Hello👋!")
    }

    @Test func changedSourceOrInvalidRangesHaveNoReplacementBaseline() {
        #expect(InputTranslationPolicy.replacingSelection(in: "前再见后",
            range: TextSelection(location: 1, length: 2), source: "你好", translation: "Hello") == nil)
        for range in [TextSelection(location: -1, length: 2), TextSelection(location: 1, length: Int.max),
                      TextSelection(location: Int.max, length: 2), TextSelection(location: 0, length: 0)] {
            #expect(InputTranslationPolicy.replacingSelection(in: "你好", range: range,
                source: "你好", translation: "Hello") == nil)
        }
    }

    @Test func splittingAnEmojiSurrogateIsRejected() {
        #expect(InputTranslationPolicy.replacingSelection(in: "👋你好",
            range: TextSelection(location: 1, length: 1), source: "?", translation: "Hello") == nil)
    }
}

struct TranslationDirectionTests {
    @Test func chineseAutomaticallyTargetsEnglish() throws {
        let request = try TranslationDirection.chineseEnglish.request(text: "你好，请帮我创建一个项目。",
            fixedTarget: .simplifiedChinese, preserveCode: true)
        #expect(request.source == .simplifiedChinese)
        #expect(request.target == .english)
    }

    @Test func englishAutomaticallyTargetsSimplifiedChinese() throws {
        let request = try TranslationDirection.chineseEnglish.request(text: "Hello, please help me create a new project.",
            fixedTarget: .english, preserveCode: true)
        #expect(request.source == .english)
        #expect(request.target == .simplifiedChinese)
    }

    @Test func traditionalChineseAlsoTargetsEnglish() throws {
        let request = try TranslationDirection.chineseEnglish.request(text: "請幫我建立專案",
            fixedTarget: .french, preserveCode: true)
        #expect(request.source == .traditionalChinese)
        #expect(request.target == .english)
    }

    @Test func protectedChineseCodeDoesNotChangeEnglishDirection() throws {
        let request = try TranslationDirection.chineseEnglish.request(text: "Please edit `繁體中文.swift` and keep its filename.",
            fixedTarget: .english, preserveCode: true)
        #expect(request.source == .english)
        #expect(request.target == .simplifiedChinese)
    }

    @Test func protectedOnlyTextNeedsNoTranslationPair() throws {
        let request = try TranslationDirection.chineseEnglish.request(text: "`你好.swift` https://example.com/hello",
            fixedTarget: .english, preserveCode: true)
        #expect(request.source == request.target)
    }

    @Test func fixedTargetRetainsOtherLanguageAndExplicitSource() throws {
        let request = try TranslationDirection.fixedTarget.request(text: "你好", source: .simplifiedChinese,
            fixedTarget: .japanese, preserveCode: false)
        #expect(request.source == .simplifiedChinese)
        #expect(request.target == .japanese)
        #expect(!request.preserveCode)
    }

    @Test func fixedEnglishTargetDoesNotSilentlyReverse() throws {
        let request = try TranslationDirection.fixedTarget.request(text: "Hello, world!",
            fixedTarget: .english, preserveCode: true)
        #expect(request.target == .english)
    }

    @Test func otherSourcesRequireFixedTargetMode() {
        #expect(throws: TranslationFailure.self) {
            try TranslationDirection.chineseEnglish.request(text: "こんにちは、これは日本語の文章です。", source: .japanese,
                fixedTarget: .english, preserveCode: true)
        }
    }

}

import Foundation
import Testing
@testable import TypeBridgeCore

struct TranslationProgressTests {
    @Test func countsOnlyResponsesThatArrivedEvenOutOfOrder() throws {
        var tracker = TranslationProgressTracker(texts: ["你好", "👨‍👩‍👧‍👦 再见", "完成"])
        #expect(tracker.progress == TranslationProgress(completedCharacters: 0, totalCharacters: 8))
        #expect(try tracker.complete(index: 1, translation: "Goodbye") == TranslationProgress(completedCharacters: 4, totalCharacters: 8))
        #expect(try tracker.complete(index: 0, translation: "Hello").completedCharacters == 6)
        #expect(try tracker.complete(index: 2, translation: "Done").completedCharacters == 8)
    }

    @Test func badOrDuplicateResponsesCannotInflateProgress() throws {
        var tracker = TranslationProgressTracker(texts: ["你好", "谢谢"])
        _ = try tracker.complete(index: 0, translation: "Hello")
        #expect(throws: TranslationFailure.self) { try tracker.complete(index: 0, translation: "Again") }
        #expect(throws: TranslationFailure.self) { try tracker.complete(index: 3, translation: "Extra") }
        #expect(throws: TranslationFailure.self) { try tracker.complete(index: 1, translation: " \n") }
        #expect(tracker.progress.completedCharacters == 2)
    }

    @Test func protectedCodeAndStructureAreNotReportedAsTranslated() {
        let document = TranslationDocument("# 你好\n\n- 谢谢 `test()` https://example.com", preserveCode: true)
        let texts = document.translatableIndices.map { document.segments[$0].text }
        let tracker = TranslationProgressTracker(texts: texts)
        #expect(tracker.progress.totalCharacters == 4)
        #expect(tracker.progress.completedCharacters == 0)
    }

    @Test func emptyBatchHasZeroCharacters() {
        #expect(TranslationProgressTracker(texts: []).progress == TranslationProgress(completedCharacters: 0, totalCharacters: 0))
    }
}

struct FeedbackPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 280, height: 64)

    @Test func staysBelowTheInputWhenSpaceAllows() {
        let anchor = CGRect(x: 200, y: 500, width: 2, height: 20)
        let frame = FeedbackPlacement.frame(size: size, anchor: anchor, visible: screen)
        #expect(frame.maxY < anchor.minY)
        #expect(frame.minX == anchor.minX)
    }

    @Test func movesAboveInputsNearBottomAndClampsRightEdge() {
        let anchor = CGRect(x: 1400, y: 20, width: 2, height: 20)
        let frame = FeedbackPlacement.frame(size: size, anchor: anchor, visible: screen)
        #expect(frame.minY > anchor.maxY)
        #expect(frame.maxX == screen.maxX - 12)
    }

    @Test func respectsSecondScreenWithNegativeCoordinates() {
        let second = CGRect(x: -1600, y: -300, width: 1600, height: 1000)
        let frame = FeedbackPlacement.frame(size: size, anchor: CGRect(x: -1700, y: 690, width: 20, height: 20), visible: second)
        #expect(second.contains(frame))
        #expect(frame.minX == second.minX + 12)
    }

    @Test func clampsLargeSelectionAndSmallScreen() {
        let visible = CGRect(x: 0, y: 0, width: 220, height: 160)
        let frame = FeedbackPlacement.frame(size: size, anchor: CGRect(x: -20, y: -30, width: 250, height: 230), visible: visible)
        #expect(visible.contains(frame))
        #expect(frame.width == 196)
    }
}

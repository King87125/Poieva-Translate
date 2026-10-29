import Foundation
import Testing
@testable import TypeBridgeCore

@Suite struct SourcePersonConstraintTests {
    @Test func recognizesExplicitActorsWithoutGuessingOmittedSubjects() {
        #expect(SourcePersonConstraint.detect(in: "虽然很累，我还是先去病房。", source: .simplifiedChinese, target: .english) == .singular)
        #expect(SourcePersonConstraint.detect(in: "我們會先確認情況。", source: .traditionalChinese, target: .english) == .plural)
        #expect(SourcePersonConstraint.detect(in: "虽然很累，还是先去病房。", source: .simplifiedChinese, target: .english) == nil)
        #expect(SourcePersonConstraint.detect(in: "我的世界是一款游戏。", source: .simplifiedChinese, target: .english) == nil)
        #expect(SourcePersonConstraint.detect(in: "我国将发布新计划。", source: .simplifiedChinese, target: .english) == nil)
        #expect(SourcePersonConstraint.detect(in: "我会检查。我们会一起签字。", source: .simplifiedChinese, target: .english) == nil)
        #expect(SourcePersonConstraint.detect(in: "I returned to the office.", source: .english, target: .simplifiedChinese) == .singular)
        #expect(SourcePersonConstraint.detect(in: "Chapter I: Introduction", source: .english, target: .simplifiedChinese) == nil)
        #expect(SourcePersonConstraint.detect(in: "US offices", source: .english, target: .simplifiedChinese) == nil)
    }

    @Test func rejectsLostFirstPersonButAllowsValidFormsAndQuotedSpeech() throws {
        let source = "虽然很累，我还是去了病房。"
        #expect(throws: TranslationAssistanceFailure.self) {
            try SourcePersonConstraint.validate(original: source, translation: "She went to the ward.", source: .simplifiedChinese, target: .english)
        }
        try SourcePersonConstraint.validate(original: source, translation: "Although tired, I went to the ward.", source: .simplifiedChinese, target: .english)
        try SourcePersonConstraint.validate(original: "我们会检查。", translation: "Our team will check.", source: .simplifiedChinese, target: .english)
        try SourcePersonConstraint.validate(original: "I returned to the office.", translation: "我回到了办公室。", source: .english, target: .simplifiedChinese)
        #expect(throws: TranslationAssistanceFailure.self) {
            try SourcePersonConstraint.validate(original: "I returned to the office.", translation: "他回到了办公室。", source: .english, target: .simplifiedChinese)
        }
        try SourcePersonConstraint.validate(original: "她说：“我会回来。”", translation: "She said, ‘I'll be back.’", source: .simplifiedChinese, target: .english)
    }

    @Test func refinementCarriesSourceConstraintAndRejectsAConflictingValidJSONResponse() throws {
        let request = TranslationRefinementRequest(originals: ["我还是先去了病房。"], drafts: ["I went to the ward first."],
            source: .simplifiedChinese, target: .english, guidance: .init(context: .init(before: "Dr. Lin is a male surgeon.", after: "The family is waiting.")))
        let object = try #require(JSONSerialization.jsonObject(with: Data(request.payload().utf8)) as? [String: Any])
        let segments = try #require(object["segments"] as? [[String: String]])
        #expect(segments.first?["sourcePersonConstraint"] == "first_person_singular")
        let passage = try #require(object["passage"] as? [[String: String]])
        #expect(passage.map { $0["kind"] } == ["before", "source", "after"])
        #expect(passage[1]["text"] == "我还是先去了病房。" && passage[1]["id"] == "0")
        #expect(passage.allSatisfy { $0["draft"] == nil })
        #expect(throws: TranslationAssistanceFailure.self) {
            try request.decode(#"{"translations":[{"id":"0","text":"Dr. Lin went to the ward first."}]}"#)
        }
        #expect(try request.decode(#"{"translations":[{"id":"0","text":"I went to the ward first."}]}"#) == ["I went to the ward first."])
    }

    @Test func blankReferenceDoesNotCountAsContextButMeaningfulWhitespaceIsPreserved() throws {
        let blank = TranslationContext(before: " \n\t", after: "\u{3000}\r\n")
        #expect(blank.isEmpty && blank.before.isEmpty && blank.after.isEmpty)
        #expect(try TranslationGuidance(context: blank).resolved(for: ["你好"], target: .english) == nil)
        let meaningful = TranslationContext(before: "Previous.\n\n", after: "\nFollowing.")
        #expect(meaningful.before == "Previous.\n\n" && meaningful.after == "\nFollowing.")
    }
}

import Testing
import AppKit
@testable import TypeBridgeCore

struct WritebackPolicyTests {
    private func state(pid: Int32 = 100, focus: Bool = true, text: String? = "帮我创建一个项目👋", selection: TextSelection? = TextSelection(location: 10, length: 0)) -> WritebackState {
        WritebackState(processID: pid, hasSameFocus: focus, text: text, selection: selection)
    }

    @Test
    func testAllowsUnchangedTarget() {
        #expect(WritebackPolicy.refusal(original: state(), current: state()) == nil)
    }

    @Test
    func testRefusesAnotherApplicationEvenWithSameText() {
        #expect(WritebackPolicy.refusal(original: state(), current: state(pid: 101)) != nil)
    }

    @Test
    func testRefusesAnotherFieldInSameApplication() {
        #expect(WritebackPolicy.refusal(original: state(), current: state(focus: false)) != nil)
    }

    @Test
    func testNeverOverwritesNewUserInput() {
        #expect(WritebackPolicy.refusal(original: state(), current: state(text: "帮我创建一个项目👋，用 Swift")) != nil)
    }

    @Test
    func testDoesNotTreatUnreadableTextAsUnchanged() {
        #expect(WritebackPolicy.refusal(original: state(), current: state(text: nil)) != nil)
        #expect(WritebackPolicy.refusal(original: state(text: nil), current: state(text: nil)) != nil)
    }

    @Test
    func testRefusesChangedSelection() {
        #expect(WritebackPolicy.refusal(original: state(), current: state(selection: TextSelection(location: 0, length: 5))) != nil)
    }

    @Test
    func testRefusesLostSelectionInformation() {
        #expect(WritebackPolicy.refusal(original: state(), current: state(selection: nil)) != nil)
    }
}

struct TranslationDocumentTests {
    @Test
    func testPlainTextKeepsLeadingAndTrailingWhitespace() throws {
        let document = TranslationDocument("\n  你好世界  \n", preserveCode: true)
        #expect(try document.assemble([0: "Hello world"]) == "\n  Hello world  \n")
    }

    @Test
    func testInlineCodeAndURLAreNeverSentForTranslation() throws {
        let document = TranslationDocument("请修改 `src/main.swift` 并查看 https://example.com/a?q=中文", preserveCode: true)
        let prose = document.translatableIndices.map { document.segments[$0].text }.joined()
        #expect(prose.contains("main.swift") == false)
        #expect(prose.contains("example.com") == false)
        #expect(try document.assemble([0: "Please edit", 2: "and see"]) == "Please edit `src/main.swift` and see https://example.com/a?q=中文")
    }

    @Test
    func testFencedMultilineCodeIsVerbatim() throws {
        let code = "```swift\nlet 中文 = \"你好\"\nprint(中文)\n```"
        let document = TranslationDocument("请检查\n\(code)\n谢谢", preserveCode: true)
        #expect(try document.assemble([0: "Please check", 2: "Thank you"]) == "Please check\n\(code)\nThank you")
    }

    @Test
    func testUnclosedCodeFenceProtectsRestOfText() throws {
        let original = "```swift\nlet text = \"你好\""
        let document = TranslationDocument(original, preserveCode: true)
        #expect(document.translatableIndices.isEmpty)
        #expect(try document.assemble([:]) == original)
    }

    @Test
    func testRejectsMissingExtraOrEmptyBatchResults() {
        let document = TranslationDocument("修改 `a` 谢谢", preserveCode: true)
        #expect(throws: TranslationFailure.self) { try document.assemble([0: "Edit"]) }
        #expect(throws: TranslationFailure.self) { try document.assemble([0: "Edit", 2: "Thanks", 3: "Extra"]) }
        #expect(throws: TranslationFailure.self) { try document.assemble([0: "Edit", 2: "  \n"]) }
    }

    @Test
    func testResponseOrderDoesNotChangeSourceOrder() throws {
        let document = TranslationDocument("你好 `hello()` 再见", preserveCode: true)
        #expect(try document.assemble([2: "Goodbye", 0: "Hello"]) == "Hello `hello()` Goodbye")
    }

    @Test
    func testCanDisableProtection() throws {
        let document = TranslationDocument("`你好`", preserveCode: false)
        #expect(document.translatableIndices == [0])
        #expect(try document.assemble([0: "`Hello`"]) == "`Hello`")
    }

    @Test func testChinesePunctuationDoesNotHideProseAfterURL() throws {
        let document = TranslationDocument("请看 https://example.com，然后继续。", preserveCode: true)
        #expect(document.translatableIndices.count == 2)
        #expect(try document.assemble([0: "See", 2: ", then continue."]) == "See https://example.com, then continue.")
    }

    @Test
    func testWhitespaceAndEmojiRoundTrip() throws {
        let original = "\n👋 `你好`\n\nhttps://example.com\n"
        let document = TranslationDocument(original, preserveCode: true)
        let translations = Dictionary(uniqueKeysWithValues: document.translatableIndices.map { ($0, document.segments[$0].text) })
        #expect(try document.assemble(translations) == original)
    }
}

struct LanguageTests {
    @Test
    func testRegionalLanguageNormalization() {
        #expect(AppLanguage.detected("en-US") == .english)
        #expect(AppLanguage.detected("zh-CN") == .simplifiedChinese)
        #expect(AppLanguage.detected("zh-Hant-TW") == .traditionalChinese)
        #expect(AppLanguage.detected("pt-PT") == .portuguese)
        #expect(AppLanguage.detected("xx-unknown") == nil)
    }

    @Test
    func testAutomaticIsNeverAnOutputLanguage() {
        #expect(AppLanguage.targets.contains(.automatic) == false)
    }
}

struct ChineseLanguageRegressionTests {
    @Test func shortSharedGreetingsUseSimplifiedChinese() throws {
        for text in ["你好", "您好", "中文"] {
            let request = TranslationRequest(text: text, target: .english)
            #expect(try LanguageDetection.source(for: request) == .simplifiedChinese)
        }
    }

    @Test func actualTraditionalCharactersRemainTraditional() throws {
        let traditional = TranslationRequest(text: "請幫我建立專案", target: .english)
        let simplified = TranslationRequest(text: "请帮我创建项目", target: .english)
        #expect(try LanguageDetection.source(for: traditional) == .traditionalChinese)
        #expect(try LanguageDetection.source(for: simplified) == .simplifiedChinese)
    }

    @Test func protectedCodeDoesNotDetermineProseLanguage() throws {
        let request = TranslationRequest(text: "Please edit `繁體中文.swift` and keep the filename.", target: .simplifiedChinese)
        #expect(try LanguageDetection.source(for: request) == .english)
    }

    @Test func chineseScriptConversionPreservesCodeAndURLs() throws {
        let text = "請修改 `漢字.swift`，參考 https://example.com/漢字"
        let result = try ChineseScript.convert(text, to: .simplifiedChinese, preserveCode: true)
        #expect(result == "请修改 `漢字.swift`，参考 https://example.com/漢字")
    }

    @Test func conversionWorksInBothDirectionsWithoutTranslationModels() throws {
        #expect(try ChineseScript.convert("请创建项目", to: .traditionalChinese, preserveCode: true) == "請創建項目")
        #expect(try ChineseScript.convert("你好", to: .simplifiedChinese, preserveCode: true) == "你好")
    }

    @Test func manuallySelectedLanguageTakesPriority() throws {
        let request = TranslationRequest(text: "你好", source: .traditionalChinese, target: .english)
        #expect(try LanguageDetection.source(for: request) == .traditionalChinese)
    }
}

@MainActor
struct ClipboardSnapshotTests {
    @Test func restoresAllOriginalFormats() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("原来的剪贴板👋", forType: .string)
        let richData = Data("{\\rtf1 original}".utf8)
        item.setData(richData, forType: .rtf)
        pasteboard.writeObjects([item])
        let snapshot = ClipboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Translation", forType: .string)
        snapshot.restore(ifOwned: pasteboard.changeCount, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "原来的剪贴板👋")
        #expect(pasteboard.data(forType: .rtf) == richData)
    }

    @Test func doesNotOverwriteANewerUserCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original", forType: .string)
        let snapshot = ClipboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Translation", forType: .string)
        let owned = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("User copied this later", forType: .string)
        snapshot.restore(ifOwned: owned, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "User copied this later")
    }

    @Test func restoresAnOriginallyEmptyClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let snapshot = ClipboardSnapshot(pasteboard)
        pasteboard.setString("Translation", forType: .string)
        snapshot.restore(ifOwned: pasteboard.changeCount, to: pasteboard)
        #expect((pasteboard.pasteboardItems ?? []).isEmpty)
    }
}

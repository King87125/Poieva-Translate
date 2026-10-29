import AppKit
import Testing
@testable import TypeBridgeCore

struct LayoutPreservationTests {
    private func translated(_ text: String, values: [String: String]) throws -> String {
        let document = TranslationDocument(text, preserveCode: true)
        var translations: [Int: String] = [:]
        for index in document.translatableIndices {
            let source = document.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            translations[index] = values[source]
        }
        return try document.assemble(translations)
    }

    @Test func paragraphSeparatorsAndIndentationStayExact() throws {
        let result = try translated("标题\r\n\r\n  第一段\n\t第二段\u{2028}第三段",
            values: ["标题": "Title", "第一段": "First", "第二段": "Second", "第三段": "Third"])
        #expect(result == "Title\r\n\r\n  First\n\tSecond\u{2028}Third")
    }

    @Test func markdownHeadingsListsAndEmphasisRemainMarkup() throws {
        #expect(try translated("# 标题\n\n- [x] **完成**\n  1. 待办\n> - 引用",
            values: ["标题": "Title", "完成": "Done", "待办": "Todo", "引用": "Quote"]) ==
            "# Title\n\n- [x] **Done**\n  1. Todo\n> - Quote")
    }

    @Test func linkDestinationIsNeverTranslated() throws {
        #expect(try translated("[入口](https://example.com/中文) 后文", values: ["入口": "Entry", "后文": "After"]) ==
            "[Entry](https://example.com/中文) After")
    }

    @Test func tableDelimitersAndAlignmentArePreserved() throws {
        #expect(try translated("| 名称 | 值 |\n| :--- | ---: |\n| 项目 | 内容 |",
            values: ["名称": "Name", "值": "Value", "项目": "Item", "内容": "Content"]) ==
            "| Name | Value |\n| :--- | ---: |\n| Item | Content |")
    }

    @Test func serviceCannotAddUnexpectedParagraphBreaks() {
        let document = TranslationDocument("你好", preserveCode: true)
        #expect(throws: TranslationFailure.self) { try document.assemble([0: "Hello\nNew paragraph"]) }
    }
}

struct HTMLFormattingTests {
    @Test func headingsBoldListsAndAttributesKeepTheirOriginalMarkup() throws {
        let html = "<h2 style='color: red'>标题</h2><p>正文<strong>重点</strong></p><ol start='3'><li>事项</li></ol>"
        let document = try HTMLTranslationDocument(html: html, plainText: "标题\n正文重点\n3. 事项", preserveCode: true)
        let result = try document.render(["Title", "Body", "Important", "Item"])
        #expect(result.html == "<h2 style='color: red'>Title</h2><p>Body<strong>Important</strong></p><ol start='3'><li>Item</li></ol>")
        #expect(result.text == "Title\nBodyImportant\n3. Item")
    }

    @Test func entitiesAreDecodedForTranslationAndNewMarkupIsEscaped() throws {
        let document = try HTMLTranslationDocument(html: "<p>Tom&nbsp;&amp;&nbsp;Jerry</p>",
            plainText: "Tom\u{00A0}&\u{00A0}Jerry", preserveCode: true)
        #expect(document.texts == ["Tom\u{00A0}&\u{00A0}Jerry"])
        let result = try document.render(["汤姆 & 杰瑞 <朋友>"])
        #expect(result.html == "<p>汤姆 &amp; 杰瑞 &lt;朋友&gt;</p>")
        #expect(result.text == "汤姆 & 杰瑞 <朋友>")
    }

    @Test func codeAndLinkAttributesRemainUntouched() throws {
        let document = try HTMLTranslationDocument(
            html: "<p>修改 <code>foo(中文)</code>，参见 <a href='https://example.com/中文'>链接</a></p>",
            plainText: "修改 foo(中文)，参见 链接", preserveCode: true)
        #expect(document.texts == ["修改 ", "，参见 ", "链接"])
        let result = try document.render(["Edit", ", see", "link"])
        #expect(result.html == "<p>Edit <code>foo(中文)</code>, see <a href='https://example.com/中文'>link</a></p>")
        #expect(result.text == "Edit foo(中文), see link")
    }

    @Test func repeatedTextInDifferentBlocksUsesItsOwnTranslation() throws {
        let document = try HTMLTranslationDocument(html: "<p>你好</p><p><em>你好</em></p>", plainText: "你好\n你好", preserveCode: true)
        let result = try document.render(["Hello", "Hi"])
        #expect(result.html == "<p>Hello</p><p><em>Hi</em></p>")
        #expect(result.text == "Hello\nHi")
    }

    @Test func quotedTagDelimitersAreNotParsedAsText() throws {
        let document = try HTMLTranslationDocument(html: "<!--StartFragment--><p data-label='x>y'>你好</p><!--EndFragment-->",
            plainText: "你好", preserveCode: true)
        #expect(try document.render(["Hello"]).html == "<!--StartFragment--><p data-label='x>y'>Hello</p><!--EndFragment-->")
    }

    @Test func numericEmojiEntitiesUseTheCorrectPlainTextRanges() throws {
        let document = try HTMLTranslationDocument(html: "<p>&#x1F44B;你好</p>", plainText: "👋你好", preserveCode: true)
        #expect(try document.render(["👋Hello"]).text == "👋Hello")
    }

    @Test func mismatchedClipboardContentCannotLoseUnmappedProse() {
        #expect(throws: FormattingFailure.self) {
            try HTMLTranslationDocument(html: "<p>你好</p>", plainText: "你好\n另一段正文", preserveCode: true)
        }
    }

    @Test func attachmentsAndUnrecognizedEntitiesRequirePreviewInstead() {
        for html in ["<p>你好<img src='private-image'></p>", "<p>&unknown;你好</p>", "<p title='unterminated>你好"] {
            #expect(throws: FormattingFailure.self) {
                try HTMLTranslationDocument(html: html, plainText: "你好", preserveCode: true)
            }
        }
    }

    @Test func incompleteRichTranslationsNeverProducePartialMarkup() throws {
        let document = try HTMLTranslationDocument(html: "<p>你好</p><p>再见</p>", plainText: "你好\n再见", preserveCode: true)
        #expect(throws: TranslationFailure.self) { try document.render(["Hello"]) }
        #expect(throws: TranslationFailure.self) { try document.render(["Hello", " "]) }
    }
}

@MainActor
struct RTFFormattingTests {
    private func rtf(_ text: NSAttributedString) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    @Test func fontsBoldParagraphSpacingAndNewlinesSurviveLongerTranslations() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let source = NSMutableAttributedString(string: "标题\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .paragraphStyle: paragraph])
        source.append(NSAttributedString(string: "正文", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let document = try AttributedTranslationDocument(data: rtf(source), plainText: source.string, preserveCode: true)
        let result = try document.render(["Longer title", "Body"])
        #expect(result.text == "Longer title\nBody")
        let rendered = try NSAttributedString(data: #require(result.rtf), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let titleFont = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyFont = try #require(rendered.attribute(.font, at: 13, effectiveRange: nil) as? NSFont)
        #expect(titleFont.pointSize == 18)
        #expect(titleFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(bodyFont.pointSize == 12)
        let style = try #require(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineSpacing == 6)
    }

    @Test func monospaceFontDoesNotPreventProseTranslation() throws {
        let source = NSMutableAttributedString(string: "请修改 ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        source.append(NSAttributedString(string: "中文说明", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        let document = try AttributedTranslationDocument(data: rtf(source), plainText: source.string, preserveCode: true)
        #expect(document.texts.count == 2)
        let result = try document.render(["Please edit", "Chinese description"])
        #expect(result.text == "Please edit Chinese description")
        let rendered = try NSAttributedString(data: #require(result.rtf), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let font = try #require(rendered.attribute(.font, at: 12, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }

    @Test func mismatchedSourceAndIncompleteResultsAreRejected() throws {
        let source = NSAttributedString(string: "你好", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let data = try rtf(source)
        #expect(throws: FormattingFailure.self) { try AttributedTranslationDocument(data: data, plainText: "再见", preserveCode: true) }
        let document = try AttributedTranslationDocument(data: data, plainText: source.string, preserveCode: true)
        #expect(throws: TranslationFailure.self) { try document.render([]) }
    }
}

struct SelectionWritebackRegressionTests {
    private func state(_ text: String, location: Int = 100, focus: Bool = true) -> WritebackState {
        WritebackState(processID: 1, hasSameFocus: focus, text: text, selection: TextSelection(location: location, length: text.utf16.count))
    }

    @Test func documentOffsetsDoNotRequireMatchingBlockOffsets() {
        #expect(InputTranslationPolicy.selectionWritebackPlan(original: state("你好"), current: state("你好"),
            editorText: "当前块", translation: "Hello") == .replace(expectedFullText: nil))
    }

    @Test func genuineSelectedTextChangesStillRefuseReplacement() {
        if case .refuse = InputTranslationPolicy.selectionWritebackPlan(original: state("你好"), current: state("再见"),
            editorText: "当前块", translation: "Hello") {} else { Issue.record("Changed selected text must be refused") }
    }

    @Test func movingSelectionOrFocusStillRefusesReplacement() {
        for current in [state("你好", location: 101), state("你好", focus: false)] {
            if case .refuse = InputTranslationPolicy.selectionWritebackPlan(original: state("你好"), current: current,
                editorText: nil, translation: "Hello") {} else { Issue.record("Changed target must be refused") }
        }
    }

    @Test func alignedEditorValuesProvideAFullVerificationBaseline() {
        #expect(InputTranslationPolicy.selectionWritebackPlan(original: state("你好", location: 1), current: state("你好", location: 1),
            editorText: "前你好后", translation: "Hello") == .replace(expectedFullText: "前Hello后"))
    }
}

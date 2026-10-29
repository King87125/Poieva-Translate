import AppKit
import TypeBridgeCore

@MainActor
struct TranslatedContent {
    let text: String
    var html: String?
    var rtf: Data?
    var writebackRefusal: String?

    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let html { item.setString(html, forType: .html) }
        if let rtf { item.setData(rtf, forType: .rtf) }
        return item
    }
}

@MainActor
enum CapturedTextFormat {
    case plain
    case html(HTMLTranslationDocument)
    case attributed(AttributedTranslationDocument)
    case unavailable

    static func capture(html: Data?, rtf: Data?, declaresRichText: Bool, text: String,
                        preserveCode: Bool, scope: EditorScope) -> Self {
        if let html {
            guard let source = String(data: html, encoding: .utf8),
                  let document = try? HTMLTranslationDocument(html: source, plainText: text, preserveCode: preserveCode) else {
                // Do not discard media or block structure by falling back to a less complete format.
                return .unavailable
            }
            return .html(document)
        }
        if let rtf, let document = try? AttributedTranslationDocument(data: rtf, plainText: text, preserveCode: preserveCode) {
            return .attributed(document)
        }
        if declaresRichText { return .unavailable }
        // A multiline web selection may span differently formatted blocks. Without
        // rich clipboard data, a plain paste cannot promise to preserve those blocks.
        if scope != .nativeInput, text.contains(where: { $0.isNewline }) { return .unavailable }
        return .plain
    }

    func translate(_ request: TranslationRequest, using provider: any TranslationProvider,
                   progress: TranslationProgressHandler? = nil) async throws -> TranslatedContent {
        switch self {
        case .plain:
            return TranslatedContent(text: try await provider.translate(request, progress: progress))
        case .unavailable:
            return TranslatedContent(text: try await provider.translate(request, progress: progress), writebackRefusal: FormattingFailure.cannotPreserve.localizedDescription)
        case let .html(document):
            let values = try await provider.translateSegments(document.texts, for: request, progress: progress)
            let result = try document.render(values)
            return TranslatedContent(text: result.text, html: result.html)
        case let .attributed(document):
            let values = try await provider.translateSegments(document.texts, for: request, progress: progress)
            let result = try document.render(values)
            return TranslatedContent(text: result.text, rtf: result.rtf,
                writebackRefusal: result.rtf == nil ? FormattingFailure.cannotPreserve.localizedDescription : nil)
        }
    }
}

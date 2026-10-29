import AppKit

/// Rebuild attributed runs with their original attributes and paragraph separators.
/// RTF is decoded locally; no HTML rendering or external resource loading is used.
@MainActor
public final class AttributedTranslationDocument {
    public struct Result {
        public let text: String
        public let rtf: Data?
    }
    private struct Run {
        let range: NSRange
        let attributes: [NSAttributedString.Key: Any]
        let document: TranslationDocument
    }
    private let source: NSAttributedString
    private let runs: [Run]
    public let texts: [String]

    public init(data: Data, plainText: String, preserveCode: Bool) throws {
        guard data.count <= 2_000_000 else { throw FormattingFailure.cannotPreserve }
        let source = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        guard source.string == plainText else { throw FormattingFailure.cannotPreserve }
        var runs: [Run] = []
        var hasAttachment = false
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            if attributes[.attachment] != nil { hasAttachment = true; return }
            let text = (source.string as NSString).substring(with: range)
            runs.append(Run(range: range, attributes: attributes, document: TranslationDocument(text, preserveCode: preserveCode)))
        }
        guard !hasAttachment else { throw FormattingFailure.cannotPreserve }
        self.source = source
        self.runs = runs
        self.texts = runs.flatMap { run in run.document.translatableIndices.map { run.document.segments[$0].text } }
        guard texts.count <= 256 else { throw FormattingFailure.cannotPreserve }
    }

    public func render(_ translations: [String]) throws -> Result {
        guard translations.count == texts.count else { throw TranslationFailure.incompleteResponse }
        var offset = 0
        var replacements: [(NSRange, NSAttributedString)] = []
        for run in runs {
            var values: [Int: String] = [:]
            for index in run.document.translatableIndices {
                values[index] = translations[offset]
                offset += 1
            }
            let text = try run.document.assemble(values)
            replacements.append((run.range, NSAttributedString(string: text, attributes: run.attributes)))
        }
        let result = NSMutableAttributedString(attributedString: source)
        for (range, text) in replacements.reversed() { result.replaceCharacters(in: range, with: text) }
        let rtf = try? result.data(from: NSRange(location: 0, length: result.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return Result(text: result.string, rtf: rtf)
    }
}

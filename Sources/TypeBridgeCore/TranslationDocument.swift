import Foundation

/// Protect literal code and URLs without asking a translation model to reproduce placeholders.
public struct TranslationDocument: Sendable {
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let isProtected: Bool
    }

    public let segments: [Segment]

    public init(_ text: String, preserveCode: Bool) {
        guard preserveCode else {
            segments = Self.preserveLayout(text)
            return
        }
        let pattern = #"```[\s\S]*?(?:```|\z)|`[^`\n]+`|\]\([^\n]*?\)|https?://[^\s<>`"，。！？；、（）【】「」『』“”‘’]+"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: fullRange)
        var result: [Segment] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                result.append(Segment(text: String(text[cursor..<range.lowerBound]), isProtected: false))
            }
            result.append(Segment(text: String(text[range]), isProtected: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(Segment(text: String(text[cursor...]), isProtected: false))
        }
        segments = result.flatMap { $0.isProtected ? [$0] : Self.preserveLayout($0.text) }
    }

    /// Keep paragraph separators and Markdown layout out of the translation service.
    private static func preserveLayout(_ text: String) -> [Segment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixPattern = #"^[ \t]*(?:(?:[#]{1,6}[ \t]+)|(?:>[ \t]*)+|(?:[-+*][ \t]+(?:\[[ xX]\][ \t]+)?)|(?:[0-9]+[.)][ \t]+))"#
        let prefix = try! NSRegularExpression(pattern: prefixPattern)
        let newline = try! NSRegularExpression(pattern: #"\r\n|[\n\r\u2028\u2029]"#)
        let inline = try! NSRegularExpression(pattern: #"\*\*|__|~~|!?\[|[|*_\]]"#)
        if newline.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) == nil,
           prefix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil,
           inline.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
            return [Segment(text: text, isProtected: false)]
        }
        var result: [Segment] = []
        func appendLine(_ line: String) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !line.isEmpty { result.append(Segment(text: line, isProtected: true)) }
                return
            }
            if line.range(of: #"^[ \t]*[-:| ]{3,}[ \t]*$"#, options: .regularExpression) != nil {
                result.append(Segment(text: line, isProtected: true))
                return
            }
            var body = line
            while let match = prefix.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let range = Range(match.range, in: body) {
                result.append(Segment(text: String(body[range]), isProtected: true))
                body = String(body[range.upperBound...])
            }
            var cursor = body.startIndex
            for match in inline.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let range = Range(match.range, in: body) else { continue }
                if cursor < range.lowerBound { result.append(Segment(text: String(body[cursor..<range.lowerBound]), isProtected: false)) }
                result.append(Segment(text: String(body[range]), isProtected: true))
                cursor = range.upperBound
            }
            if cursor < body.endIndex { result.append(Segment(text: String(body[cursor...]), isProtected: false)) }
        }
        var cursor = text.startIndex
        for match in newline.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            appendLine(String(text[cursor..<range.lowerBound]))
            result.append(Segment(text: String(text[range]), isProtected: true))
            cursor = range.upperBound
        }
        appendLine(String(text[cursor...]))
        return result
    }

    public var translatableIndices: [Int] {
        segments.indices.filter { !segments[$0].isProtected && !segments[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func assemble(_ translations: [Int: String]) throws -> String {
        let expected = Set(translatableIndices)
        guard expected == Set(translations.keys), translations.values.allSatisfy({ value in
            let prose = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !prose.isEmpty && !prose.contains(where: { $0.isNewline })
        }) else {
            throw TranslationFailure.incompleteResponse
        }
        return segments.indices.map { index in
            guard let translated = translations[index] else { return segments[index].text }
            let original = segments[index].text
            let prefix = String(original.prefix(while: { $0.isWhitespace }))
            let suffix = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
            return prefix + translated.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
        }.joined()
    }
}

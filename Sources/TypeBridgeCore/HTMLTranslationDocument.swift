import Foundation

public enum FormattingFailure: LocalizedError {
    case cannotPreserve

    public var errorDescription: String? {
        L10n.tr("未能可靠保留原文格式，已保留译文，没有自动覆盖。")
    }
}

/// A lossless markup template. HTML is tokenized as data, never rendered or executed.
public struct HTMLTranslationDocument: Sendable {
    private enum Piece: Sendable {
        case markup(String)
        case text(raw: String, decoded: String, range: TextSelection, document: TranslationDocument?)
    }

    public struct Result: Sendable {
        public let text: String
        public let html: String
    }

    private let pieces: [Piece]
    private let plainText: String

    public init(html: String, plainText: String, preserveCode: Bool) throws {
        guard html.utf8.count <= 2_000_000 else { throw FormattingFailure.cannotPreserve }
        let plain = plainText as NSString
        var plainCursor = 0
        var result: [Piece] = []
        var mappedRanges: [NSRange] = []
        var contexts: [String] = []
        var cursor = html.startIndex
        let hidden: Set<String> = ["head", "style"]
        let literal: Set<String> = ["pre", "code", "kbd", "samp"]
        let unsupported: Set<String> = ["script", "img", "video", "audio", "iframe", "object", "embed", "svg", "math", "canvas", "input"]
        while cursor < html.endIndex {
            if html[cursor] == "<" {
                let end: String.Index
                if html[cursor...].hasPrefix("<!--") {
                    guard let close = html.range(of: "-->", range: cursor..<html.endIndex) else { throw FormattingFailure.cannotPreserve }
                    end = close.upperBound
                } else {
                    var index = html.index(after: cursor)
                    var quote: Character?
                    while index < html.endIndex {
                        let character = html[index]
                        if let active = quote {
                            if character == active { quote = nil }
                        } else if character == "\"" || character == "'" { quote = character }
                        else if character == ">" { break }
                        index = html.index(after: index)
                    }
                    guard index < html.endIndex, quote == nil else { throw FormattingFailure.cannotPreserve }
                    end = html.index(after: index)
                }
                let tag = String(html[cursor..<end])
                result.append(.markup(tag))
                if !tag.hasPrefix("<!--"), !tag.hasPrefix("<!"), !tag.hasPrefix("<?") {
                    var name = tag.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                    let closing = name.hasPrefix("/")
                    if closing { name.removeFirst() }
                    name = String(name.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }).lowercased()
                    guard !name.isEmpty, !unsupported.contains(name) else { throw FormattingFailure.cannotPreserve }
                    if hidden.contains(name) || (preserveCode && literal.contains(name)) {
                        if closing {
                            guard contexts.last == name else { throw FormattingFailure.cannotPreserve }
                            contexts.removeLast()
                        } else if !tag.hasSuffix("/>") { contexts.append(name) }
                    }
                }
                cursor = end
                continue
            }
            let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
            let raw = String(html[cursor..<end])
            cursor = end
            if contexts.contains(where: { hidden.contains($0) }) {
                result.append(.markup(raw))
                continue
            }
            let decoded = try Self.decodeEntities(raw)
            if decoded.isEmpty { result.append(.markup(raw)); continue }
            let range = plain.range(of: decoded, options: [], range: NSRange(location: plainCursor, length: plain.length - plainCursor))
            if range.location == NSNotFound {
                guard decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FormattingFailure.cannotPreserve }
                result.append(.markup(raw))
                continue
            }
            mappedRanges.append(range)
            plainCursor = range.location + range.length
            let document = contexts.contains(where: { literal.contains($0) }) ? nil : TranslationDocument(decoded, preserveCode: preserveCode)
            result.append(.text(raw: raw, decoded: decoded,
                range: TextSelection(location: range.location, length: range.length), document: document))
        }
        guard contexts.isEmpty else { throw FormattingFailure.cannotPreserve }
        // Gaps may contain structural whitespace and list markers, but never untranslated prose.
        let gaps = NSMutableString(string: plainText)
        for range in mappedRanges.reversed() { gaps.replaceCharacters(in: range, with: "") }
        guard !(gaps as String).unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            throw FormattingFailure.cannotPreserve
        }
        self.pieces = result
        self.plainText = plainText
        guard texts.count <= 256 else { throw FormattingFailure.cannotPreserve }
    }

    public var texts: [String] {
        pieces.flatMap { piece -> [String] in
            guard case let .text(_, _, _, document?) = piece else { return [] }
            return document.translatableIndices.map { document.segments[$0].text }
        }
    }

    public func render(_ translations: [String]) throws -> Result {
        guard translations.count == texts.count else { throw TranslationFailure.incompleteResponse }
        var offset = 0
        var replacements: [(TextSelection, String)] = []
        var html = ""
        for piece in pieces {
            switch piece {
            case let .markup(raw): html += raw
            case let .text(raw, decoded, range, document):
                guard let document else { html += raw; continue }
                var values: [Int: String] = [:]
                for index in document.translatableIndices {
                    values[index] = translations[offset]
                    offset += 1
                }
                let translated = try document.assemble(values)
                html += translated == decoded ? raw : Self.escape(translated)
                replacements.append((range, translated))
            }
        }
        let text = NSMutableString(string: plainText)
        for (range, replacement) in replacements.reversed() {
            text.replaceCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
        }
        return Result(text: text as String, html: html)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
    }

    private static func decodeEntities(_ text: String) throws -> String {
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "hellip": "…", "bull": "•",
            "copy": "©", "reg": "®", "trade": "™", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}"]
        let expression = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z][a-zA-Z0-9]+);"#)
        let result = NSMutableString(string: text)
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let entity = (text as NSString).substring(with: match.range(at: 1))
            let replacement: String
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                guard let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) else {
                    throw FormattingFailure.cannotPreserve
                }
                replacement = String(scalar)
            } else {
                guard let value = named[entity] else { throw FormattingFailure.cannotPreserve }
                replacement = value
            }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}

import Foundation

/// Interface language is independent of source/target languages and service data.
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }
    public var nativeName: String { self == .english ? "English" : "简体中文" }
    public var locale: Locale { Locale(identifier: rawValue) }

    public static func suggested(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        for identifier in preferredLanguages {
            let language = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            if language == "zh" || language.hasPrefix("zh-") { return .simplifiedChinese }
            if language == "en" || language.hasPrefix("en-") { return .english }
        }
        return .english
    }
}

public struct InterfaceLanguagePreference {
    public static let key = "interfaceLanguage"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var selection: InterfaceLanguage? {
        defaults.string(forKey: Self.key).flatMap(InterfaceLanguage.init(rawValue:))
    }
    public var requiresSelection: Bool { selection == nil }
    public var effectiveLanguage: InterfaceLanguage { selection ?? .suggested() }

    public func save(_ language: InterfaceLanguage) {
        defaults.set(language.rawValue, forKey: Self.key)
        // App-scoped override: native open/save dialogs follow the choice on launch.
        defaults.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Localized interpolation keeps values (user names, service names and errors)
/// separate from catalog keys. Values are substituted in one pass, never parsed
/// as format strings or recursively interpreted as placeholders.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    // The interface language is fixed for a session. Settings save the next
    // session's choice, avoiding discarded drafts or interrupted translations.
    private static let lock = NSLock()
    private static var sessionLanguage = InterfaceLanguagePreference().effectiveLanguage
    public static var language: InterfaceLanguage {
        lock.lock(); defer { lock.unlock() }; return sessionLanguage
    }
    public static func configure(_ language: InterfaceLanguage) {
        lock.lock(); defer { lock.unlock() }; sessionLanguage = language
    }
    public static func tr(_ message: LocalizedMessage) -> String {
        render(message, language: language)
    }
    public static func render(_ message: LocalizedMessage, language: InterfaceLanguage) -> String {
        substitute(value(for: message.key, language: language), arguments: message.arguments)
    }
    public static func value(for key: String, language: InterfaceLanguage) -> String {
        catalog(language)[key] ?? key
    }

    // Read once per language; no disk reads or allocations of bundles on each draw.
    private static let englishCatalog = load(.english)
    private static let chineseCatalog = load(.simplifiedChinese)
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "TypeBridge_TypeBridgeCore", withExtension: "bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }()
    static func catalog(_ language: InterfaceLanguage) -> [String: String] {
        language == .english ? englishCatalog : chineseCatalog
    }
    private static func load(_ language: InterfaceLanguage) -> [String: String] {
        guard let path = resourceBundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language.rawValue),
              let data = FileManager.default.contents(atPath: path),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return dictionary
    }
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    private static func substitute(_ template: String, arguments: [String]) -> String {
        let source = template as NSString
        var result = "", cursor = 0
        for match in placeholder.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            guard let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += arguments[index]
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}

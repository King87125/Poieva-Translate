import Foundation
import Testing
@testable import TypeBridgeCore

@Suite struct InterfaceLanguageTests {
    @Test func firstLaunchAndInvalidChoicesRequireSelection() throws {
        let suite = "Poieva.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = InterfaceLanguagePreference(defaults: defaults)
        #expect(preference.requiresSelection)
        defaults.set("unsupported", forKey: InterfaceLanguagePreference.key)
        #expect(preference.requiresSelection)
        preference.save(.english)
        #expect(!InterfaceLanguagePreference(defaults: defaults).requiresSelection)
        #expect(InterfaceLanguagePreference(defaults: defaults).selection == .english)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
    }

    @Test func savingChoicePreservesTranslationAndModelPreferences() throws {
        let suite = "Poieva.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("chineseEnglish", forKey: "inputDirection")
        defaults.set("en", forKey: "inputTarget")
        let data = Data("existing configuration".utf8)
        defaults.set(data, forKey: "services")
        let current = L10n.language
        InterfaceLanguagePreference(defaults: defaults).save(.simplifiedChinese)
        #expect(defaults.string(forKey: "inputDirection") == "chineseEnglish")
        #expect(defaults.string(forKey: "inputTarget") == "en")
        #expect(defaults.data(forKey: "services") == data)
        #expect(L10n.language == current) // A pending choice cannot alter an active session.
    }

    @Test func systemLanguageSuggestionsHaveAnEnglishFallback() {
        #expect(InterfaceLanguage.suggested(preferredLanguages: ["fr-FR"]) == .english)
        #expect(InterfaceLanguage.suggested(preferredLanguages: ["fr-FR", "zh-Hant-TW", "en-US"]) == .simplifiedChinese)
        #expect(InterfaceLanguage.suggested(preferredLanguages: ["en_US", "zh-Hans"]) == .english)
        #expect(InterfaceLanguage.suggested(preferredLanguages: []) == .english)
    }

    @Test func bothCatalogsAreCompleteAndHaveMatchingPlaceholders() {
        let chinese = L10n.catalog(.simplifiedChinese), english = L10n.catalog(.english)
        #expect(chinese.count >= 420)
        #expect(Set(chinese.keys) == Set(english.keys))
        let placeholder = try! NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func tokens(_ text: String) -> [String] {
            let source = text as NSString
            return placeholder.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) }.sorted()
        }
        for (key, value) in english {
            #expect(!value.isEmpty)
            #expect(tokens(key) == tokens(value), "Placeholder mismatch: \(key)")
            #expect(value.range(of: #"[\p{Han}]"#, options: .regularExpression) == nil,
                    "Untranslated English interface text: \(key)")
        }
    }

    @Test func interpolationPreservesUserContentWithoutReinterpretingIt() {
        let service = "My 模型 {1} %s \"quoted\""
        #expect(L10n.render("默认翻译：\(service)", language: .english) == "Default translation: \(service)")
        #expect(L10n.render("已选 \(12) 个服务", language: .english) == "12 services selected")
        #expect(L10n.render("已选 \(12) 个服务", language: .simplifiedChinese) == "已选 12 个服务")
        #expect(L10n.render("服务返回 HTTP \(429)，请检查服务配置或稍后再试。", language: .english)
            == "The service returned HTTP 429. Check its configuration or try again later.")
        #expect(L10n.render("高级参数必须是 JSON 对象，例如 {\"temperature\":0}。", language: .english)
            .contains("{\"temperature\":0}"))
        #expect(L10n.render("An uncatalogued \(service)", language: .english) == "An uncatalogued \(service)")
    }

    @Test func modelLanguageIdentifiersAndUserConfigStayIndependentOfUI() throws {
        #expect(AppLanguage.simplifiedChinese.promptName == "Simplified Chinese")
        #expect(AppLanguage.traditionalChinese.promptName == "Traditional Chinese")
        #expect(AppLanguage.english.rawValue == "en")
        let config = TranslationServiceConfiguration(name: "我的模型", baseURL: "https://example.com/v1", model: "user-model")
        let package = try TranslationServicePackage.encode([config])
        #expect(String(decoding: package, as: UTF8.self).contains("我的模型"))
    }
}

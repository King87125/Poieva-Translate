import Combine
import Foundation

public struct TranslationAssistanceSettings: Codable, Equatable, Sendable {
    public var useContext: Bool
    /// off, or the UUID of a configured remote model API. No credentials here.
    public var assistant: String
    public var preferences: TranslationPreferences
    public init(useContext: Bool = true, assistant: String = "off", preferences: TranslationPreferences = .init()) {
        self.useContext = useContext; self.assistant = assistant; self.preferences = preferences
    }
    public func validated() throws -> Self {
        guard assistant == "off" || UUID(uuidString: assistant) != nil else {
            throw TranslationAssistanceFailure.invalidPreferences
        }
        var result = self
        result.preferences = try preferences.validated()
        return result
    }

    /// Retain all personal preferences when retiring a previously selected local helper.
    public func usingRemoteAPIs(in services: [TranslationServiceConfiguration]) -> Self {
        var result = self
        if assistant == "system" || services.contains(where: { $0.id.uuidString == assistant && !$0.isRemoteModelAPI }) {
            result.assistant = "off"
        }
        return result
    }
}

@MainActor
public final class TranslationPreferenceStore: ObservableObject {
    @Published public private(set) var settings: TranslationAssistanceSettings
    @Published public private(set) var issue = ""
    public var onChange: (() -> Void)?
    public var canModify: () -> Bool = { true }
    private let defaults: UserDefaults
    private let storageKey = "translationPreferences.v1"
    private struct Saved: Codable { var version = 1; var settings: TranslationAssistanceSettings }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = .init()
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            guard data.count <= 65_536 else { throw TranslationAssistanceFailure.invalidPreferences }
            var saved = try JSONDecoder().decode(Saved.self, from: data)
            guard saved.version == 1 else { throw TranslationAssistanceFailure.invalidPreferences }
            let retiredSystemModel = saved.settings.assistant == "system"
            if retiredSystemModel { saved.settings.assistant = "off" }
            settings = try saved.settings.validated()
            if retiredSystemModel { defaults.set(try JSONEncoder().encode(Saved(settings: settings)), forKey: storageKey) }
        } catch { issue = L10n.tr("翻译偏好无法读取，已暂用默认设置；原记录未覆盖。") }
    }

    public func save(_ value: TranslationAssistanceSettings) throws {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        let value = try value.validated()
        let data = try JSONEncoder().encode(Saved(settings: value))
        guard value != settings || !issue.isEmpty else { return }
        defaults.set(data, forKey: storageKey)
        settings = value; issue = ""; onChange?()
    }
}

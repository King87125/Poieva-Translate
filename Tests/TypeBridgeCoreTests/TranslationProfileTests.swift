import Foundation
import Testing
@testable import TypeBridgeCore

struct TranslationProfileTests {
    private func fixture() -> TranslationProfileCatalog {
        let library = TerminologyLibrary(name: "产品", entries: [
            .init(source: "Poieva", sourceLanguage: .english, targetLanguage: .simplifiedChinese, preserveOriginal: true),
            .init(source: "工作台", translation: "workspace", sourceLanguage: .simplifiedChinese, targetLanguage: .english),
            .init(source: "不会命中", translation: "never sent", targetLanguage: .english)])
        let tone = ToneConfiguration(name: "简洁自然", tone: .natural, instructions: "Use short sentences.",
            exampleSource: "谢谢你的帮助", exampleTranslation: "Thanks for your help.")
        let scene = TranslationScene(name: "产品工作", glossaryIDs: [library.id], toneID: tone.id, instructions: "Do not add greetings.")
        return .init(glossaries: [library], tones: [tone], scenes: [scene], activeSceneID: scene.id)
    }
    @Test func shippedExampleImportsAndKeepsOnlyRelevantTerms() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var catalog = try TranslationProfilePackage.decode(Data(contentsOf: root.appendingPathComponent("Examples/translation-profiles.json")))
        catalog.activeSceneID = catalog.scenes.first?.id
        let value = try #require(catalog.snapshot).preferences(for: ["译入工作台已准备好。"], source: .simplifiedChinese, target: .english)
        #expect(Set(value.terms.map(\.translation)) == ["Poieva", "workspace"])
        #expect(value.tone == .concise && value.instructions.contains("Do not add greetings"))
    }
    @Test func resolvesOnlyMatchingTermsInTheCorrectDirectionAndCombinesRules() throws {
        let snapshot = try #require(fixture().snapshot)
        let english = try snapshot.preferences(for: ["打开工作台"], source: .simplifiedChinese, target: .english)
        #expect(english.terms.map(\.translation) == ["workspace"])
        #expect(english.instructions.contains("Use short sentences.") && english.instructions.contains("Do not add greetings."))
        #expect(english.instructions.contains("Style example") && !english.instructions.contains("never sent"))
        let chinese = try snapshot.preferences(for: ["Use Poieva today."], source: .english, target: .simplifiedChinese)
        #expect(chinese.terms.map(\.translation) == ["Poieva"])
        let other = try snapshot.preferences(for: ["工作台"], source: .english, target: .english)
        #expect(other.terms.isEmpty)
    }
    @Test func boundariesAvoidIncidentalASCIIFragmentsButSupportMixedWritingAndPunctuation() {
        let api = GlossaryEntry(source: "API", translation: "接口")
        #expect(api.matches("API接口、api 调用与 (API)。"))
        #expect(!api.matches("capital apis _api api2"))
        #expect(GlossaryEntry(source: "C++", translation: "C++").matches("Use C++ today."))
        #expect(GlossaryEntry(source: "工作台", translation: "workspace").matches("打开工作台界面"))
    }
    @Test func preciseLanguageOverridesGeneralConflictsAndEqualPriorityConflictsAreExplicit() throws {
        let generic = TerminologyLibrary(name: "通用", entries: [.init(source: "draft", translation: "草案")])
        let conflicting = TerminologyLibrary(name: "其他", entries: [.init(source: "draft", translation: "汇票")])
        let specific = TerminologyLibrary(name: "产品", entries: [.init(source: "draft", translation: "草稿", sourceLanguage: .english, targetLanguage: .simplifiedChinese)])
        let scene = TranslationScene(name: "写作", glossaryIDs: [generic.id, conflicting.id, specific.id])
        var snapshot = TranslationProfileSnapshot(scene: scene, glossaries: [generic, conflicting, specific], tone: nil)
        #expect(try snapshot.preferences(for: ["Save the draft."], source: .english, target: .simplifiedChinese).terms.first?.translation == "草稿")
        snapshot.glossaries = [generic, conflicting]
        #expect(throws: TranslationProfileFailure.self) { try snapshot.preferences(for: ["Save the draft."], source: .english, target: .simplifiedChinese) }
    }
    @Test func storageAllowsLargeLibrariesWithoutSendingUnrelatedEntries() throws {
        let entries = (0..<500).map { GlossaryEntry(source: "product_\($0)", translation: "产品\($0)") }
        let library = TerminologyLibrary(name: "大型术语库", entries: entries)
        let scene = TranslationScene(name: "工程", glossaryIDs: [library.id])
        let catalog = try TranslationProfileCatalog(glossaries: [library], scenes: [scene], activeSceneID: scene.id).validated()
        let result = try #require(catalog.snapshot).preferences(for: ["Use product_42."], source: .english, target: .simplifiedChinese)
        #expect(result.terms.count == 1 && result.terms[0].translation == "产品42")
        #expect(throws: TranslationProfileFailure.self) { try #require(catalog.snapshot).preferences(for: [entries.prefix(65).map(\.source).joined(separator: " ")], source: .english, target: .simplifiedChinese) }
    }
    @Test func toneAndSceneLanguageScopesDoNotChangeTranslationDirection() throws {
        var catalog = fixture(); catalog.scenes[0].target = .english
        let snapshot = try #require(catalog.snapshot)
        let chinese = try snapshot.preferences(for: ["Poieva"], source: .english, target: .simplifiedChinese)
        #expect(chinese.isEmpty)
    }
    @Test func invalidCatalogsRejectDuplicatesDanglingReferencesAndIncompleteExamples() throws {
        var catalog = fixture()
        catalog.glossaries[0].entries.append(catalog.glossaries[0].entries[0])
        #expect(throws: TranslationProfileFailure.self) { try catalog.validated() }
        catalog = fixture(); catalog.scenes[0].toneID = UUID()
        #expect(throws: TranslationProfileFailure.self) { try catalog.validated() }
        catalog = fixture(); catalog.tones[0].exampleSource = ""
        #expect(throws: TranslationProfileFailure.self) { try catalog.validated() }
        #expect(throws: TranslationProfileFailure.self) { try GlossaryEntry(source: "x", translation: "a\nb").validated() }
    }
    @Test func sceneExportIncludesDependenciesButExcludesCurrentSelectionAndServiceConfiguration() throws {
        var catalog = fixture(); catalog.glossaries.append(.init(name: "未使用的库"))
        let data = try TranslationProfilePackage.encode(catalog, kind: .scene, id: catalog.scenes[0].id)
        let result = try TranslationProfilePackage.decode(data)
        #expect(result.glossaries.count == 1 && result.tones.count == 1 && result.scenes.count == 1)
        #expect(result.activeSceneID == nil)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "version", "glossaries", "tones", "scenes"])
        let single = try TranslationProfilePackage.decode(TranslationProfilePackage.encode(catalog, kind: .glossary, id: catalog.glossaries[0].id))
        #expect(single.tones.isEmpty && single.scenes.isEmpty && single.glossaries.count == 1)
    }
    @Test func unknownFieldsCredentialsAndFutureVersionsAreRejectedBeforeImport() throws {
        let data = try TranslationProfilePackage.encode(fixture())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["apiKey"] = "never-import"
        #expect(throws: TranslationProfileFailure.self) { try TranslationProfilePackage.decode(JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "apiKey"); object["version"] = 99
        #expect(throws: TranslationProfileFailure.self) { try TranslationProfilePackage.decode(JSONSerialization.data(withJSONObject: object)) }
        object["version"] = 1
        var tones = try #require(object["tones"] as? [[String: Any]]); tones[0]["headers"] = ["Authorization": "never-import"]; object["tones"] = tones
        #expect(throws: TranslationProfileFailure.self) { try TranslationProfilePackage.decode(JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func guidanceResolvesASnapshotOnceAndKeepsContextSeparateFromRules() throws {
        let snapshot = try #require(fixture().snapshot)
        let raw = TranslationGuidance(context: .init(before: "前文", after: "后文"), profile: snapshot)
        let value = try raw.resolved(for: ["打开工作台"], target: .english, source: .simplifiedChinese)
        let resolved = try #require(value)
        #expect(resolved.profile == nil && resolved.context == raw.context)
        #expect(resolved.preferences.terms.first?.translation == "workspace")
        #expect(try resolved.resolved(for: ["打开工作台"], target: .english, source: .simplifiedChinese) == resolved)
    }
    @Test @MainActor func migrationPersistenceImportDeduplicationAndDeletionPreserveUserData() throws {
        let name = "Poieva.ProfileTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = TranslationPreferences(tone: .concise, instructions: "Keep my style.", terms: [.init(source: "译入", translation: "TypeBridge")])
        let store = TranslationProfileStore(defaults: defaults, legacyPreferences: legacy)
        #expect(store.catalog.activeScene?.name == L10n.tr("原有偏好"))
        #expect(store.catalog.glossaries.first?.entries.first?.translation == "TypeBridge")
        let active = store.catalog.activeSceneID
        let package = try TranslationProfilePackage.encode(fixture())
        let before = store.catalog
        #expect(try store.importPackage(package) == 3)
        #expect(store.catalog.activeSceneID == active)
        #expect(try store.importPackage(package) == 0)
        #expect(store.catalog.glossaries.prefix(before.glossaries.count) == before.glossaries[...])
        #expect(TranslationProfileStore(defaults: defaults).catalog == store.catalog)
        let importedScene = try #require(store.catalog.scenes.last)
        try store.select(importedScene.id)
        let libraryID = try #require(importedScene.glossaryIDs.first)
        try store.remove(libraryID, kind: .glossary)
        #expect(store.catalog.activeScene?.glossaryIDs.isEmpty == true)
        try store.remove(importedScene.id, kind: .scene)
        #expect(store.catalog.activeSceneID == nil)
        store.canModify = { false }
        #expect(throws: ServiceConfigurationFailure.self) { try store.select(active) }
    }
    @Test @MainActor func failedImportsAreAtomicAndDamagedStoredRecordsAreNotOverwritten() throws {
        let name = "Poieva.ProfileTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TranslationProfileStore(defaults: defaults)
        #expect(store.catalog.activeSceneID == nil)
        let before = store.catalog
        #expect(throws: TranslationProfileFailure.self) { try store.importPackage(Data("{}".utf8)) }
        #expect(store.catalog == before)
        let damaged = Data("broken".utf8); defaults.set(damaged, forKey: "translationProfiles.v1")
        let reloaded = TranslationProfileStore(defaults: defaults)
        #expect(!reloaded.issue.isEmpty && reloaded.catalog.activeSceneID == nil)
        #expect(defaults.data(forKey: "translationProfiles.v1") == damaged)
    }
}

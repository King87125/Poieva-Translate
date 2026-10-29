import Combine
import Foundation

public enum TranslationProfilePackage {
    public static let maximumBytes = 4_194_304
    private struct Package: Codable {
        var format = "poieva.translation-profiles"
        var version = 1
        var glossaries: [TerminologyLibrary]
        var tones: [ToneConfiguration]
        var scenes: [TranslationScene]
    }
    public static func encode(_ catalog: TranslationProfileCatalog, kind: TranslationProfileKind? = nil, id: UUID? = nil) throws -> Data {
        let valid = try catalog.validated()
        var glossaries = valid.glossaries, tones = valid.tones, scenes = valid.scenes
        if let kind, let id {
            switch kind {
            case .glossary: glossaries = glossaries.filter { $0.id == id }; tones = []; scenes = []
            case .tone: tones = tones.filter { $0.id == id }; glossaries = []; scenes = []
            case .scene:
                scenes = scenes.filter { $0.id == id }
                glossaries = glossaries.filter { library in scenes.contains { $0.glossaryIDs.contains(library.id) } }
                tones = tones.filter { tone in scenes.contains { $0.toneID == tone.id } }
            }
        }
        guard !glossaries.isEmpty || !tones.isEmpty || !scenes.isEmpty else { throw TranslationProfileFailure.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Package(glossaries: glossaries, tones: tones, scenes: scenes))
        guard data.count <= maximumBytes else { throw TranslationProfileFailure.oversized }
        return data
    }
    public static func decode(_ data: Data) throws -> TranslationProfileCatalog {
        guard data.count <= maximumBytes else { throw TranslationProfileFailure.oversized }
        func checked(_ value: Any?, fields: Set<String>) throws -> [String: Any] {
            guard let dictionary = value as? [String: Any], Set(dictionary.keys).isSubset(of: fields) else { throw TranslationProfileFailure.damaged }
            return dictionary
        }
        do {
            let root = try checked(JSONSerialization.jsonObject(with: data), fields: ["format", "version", "glossaries", "tones", "scenes"])
            for (key, fields): (String, Set<String>) in [
                ("glossaries", ["id", "name", "entries"]),
                ("tones", ["id", "name", "tone", "target", "instructions", "exampleSource", "exampleTranslation"]),
                ("scenes", ["id", "name", "glossaryIDs", "toneID", "target", "instructions"])] {
                guard let rows = root[key] as? [[String: Any]] else { throw TranslationProfileFailure.damaged }
                for row in rows {
                    _ = try checked(row, fields: fields)
                    if key == "glossaries" {
                        guard let entries = row["entries"] as? [[String: Any]] else { throw TranslationProfileFailure.damaged }
                        for entry in entries { _ = try checked(entry, fields: ["id", "source", "translation", "sourceLanguage", "targetLanguage", "preserveOriginal"]) }
                    }
                }
            }
            let package = try JSONDecoder().decode(Package.self, from: data)
            guard package.format == "poieva.translation-profiles", package.version == 1 else { throw TranslationProfileFailure.damaged }
            return try TranslationProfileCatalog(glossaries: package.glossaries, tones: package.tones, scenes: package.scenes).validated()
        } catch let error as TranslationProfileFailure { throw error }
        catch { throw TranslationProfileFailure.damaged }
    }
}

@MainActor
public final class TranslationProfileStore: ObservableObject {
    @Published public private(set) var catalog: TranslationProfileCatalog
    @Published public private(set) var issue = ""
    public var onChange: (() -> Void)?
    public var canModify: () -> Bool = { true }
    private let defaults: UserDefaults
    private let storageKey = "translationProfiles.v1"
    private struct Saved: Codable { var version = 1; var catalog: TranslationProfileCatalog }
    public init(defaults: UserDefaults, legacyPreferences: TranslationPreferences = .init()) {
        self.defaults = defaults
        catalog = .starter()
        if let data = defaults.data(forKey: storageKey) {
            do {
                guard data.count <= TranslationProfilePackage.maximumBytes else { throw TranslationProfileFailure.oversized }
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.version == 1 else { throw TranslationProfileFailure.damaged }
                catalog = try saved.catalog.validated()
            } catch { issue = L10n.tr("翻译方案无法读取，原记录已保留；当前暂不应用场景。") }
        } else {
            if !legacyPreferences.isEmpty {
                var libraries: [TerminologyLibrary] = []
                if !legacyPreferences.terms.isEmpty {
                    libraries = [.init(name: L10n.tr("原有术语"), entries: legacyPreferences.terms.map {
                        .init(source: $0.source, translation: $0.translation, targetLanguage: $0.target)
                    })]
                }
                let tone = ToneConfiguration(name: L10n.tr("原有表达偏好"), tone: legacyPreferences.tone,
                    target: legacyPreferences.target, instructions: legacyPreferences.instructions)
                let scene = TranslationScene(name: L10n.tr("原有偏好"), glossaryIDs: libraries.map(\.id), toneID: tone.id)
                catalog.glossaries += libraries; catalog.tones.append(tone); catalog.scenes.append(scene); catalog.activeSceneID = scene.id
            }
            do { try commit(catalog) }
            catch { issue = error.localizedDescription; catalog.activeSceneID = nil }
        }
    }
    public func save(_ library: TerminologyLibrary) throws {
        var next = catalog
        if let index = next.glossaries.firstIndex(where: { $0.id == library.id }) { next.glossaries[index] = library }
        else { next.glossaries.append(library) }
        try commit(next)
    }
    public func save(_ tone: ToneConfiguration) throws {
        var next = catalog
        if let index = next.tones.firstIndex(where: { $0.id == tone.id }) { next.tones[index] = tone }
        else { next.tones.append(tone) }
        try commit(next)
    }
    public func save(_ scene: TranslationScene) throws {
        var next = catalog
        if let index = next.scenes.firstIndex(where: { $0.id == scene.id }) { next.scenes[index] = scene }
        else { next.scenes.append(scene) }
        try commit(next)
    }
    public func select(_ id: UUID?) throws { var next = catalog; next.activeSceneID = id; try commit(next) }
    public func remove(_ id: UUID, kind: TranslationProfileKind) throws {
        var next = catalog
        switch kind {
        case .glossary:
            next.glossaries.removeAll { $0.id == id }
            for index in next.scenes.indices { next.scenes[index].glossaryIDs.removeAll { $0 == id } }
        case .tone:
            next.tones.removeAll { $0.id == id }
            for index in next.scenes.indices where next.scenes[index].toneID == id { next.scenes[index].toneID = nil }
        case .scene:
            next.scenes.removeAll { $0.id == id }
            if next.activeSceneID == id { next.activeSceneID = nil }
        }
        try commit(next)
    }
    public func exportPackage(kind: TranslationProfileKind? = nil, id: UUID? = nil) throws -> Data {
        try TranslationProfilePackage.encode(catalog, kind: kind, id: id)
    }
    /// Merge without overwriting, activating, or importing service credentials.
    @discardableResult public func importPackage(_ data: Data) throws -> Int {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        let incoming = try TranslationProfilePackage.decode(data)
        var next = catalog, mapping: [UUID: UUID] = [:], count = 0
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        func librarySignature(_ library: TerminologyLibrary) -> TerminologyLibrary {
            var value = library; value.id = zero
            value.entries = library.entries.map { var entry = $0; entry.id = zero; return entry }
            return value
        }
        for library in incoming.glossaries {
            if let old = next.glossaries.first(where: { librarySignature($0) == librarySignature(library) }) { mapping[library.id] = old.id }
            else {
                var copy = library; copy.id = UUID(); copy.entries = copy.entries.map { var entry = $0; entry.id = UUID(); return entry }
                mapping[library.id] = copy.id; next.glossaries.append(copy); count += 1
            }
        }
        for tone in incoming.tones {
            if let old = next.tones.first(where: { existing in var copy = tone; copy.id = existing.id; return copy == existing }) { mapping[tone.id] = old.id }
            else { var copy = tone; copy.id = UUID(); mapping[tone.id] = copy.id; next.tones.append(copy); count += 1 }
        }
        for scene in incoming.scenes {
            var copy = scene
            copy.glossaryIDs = try scene.glossaryIDs.map { guard let id = mapping[$0] else { throw TranslationProfileFailure.missingReference }; return id }
            if let toneID = scene.toneID { guard let id = mapping[toneID] else { throw TranslationProfileFailure.missingReference }; copy.toneID = id }
            if !next.scenes.contains(where: { existing in var same = copy; same.id = existing.id; return same == existing }) {
                copy.id = UUID(); next.scenes.append(copy); count += 1
            }
        }
        try commit(next)
        return count
    }
    /// A reviewed generation is added and optionally activated in one write.
    /// No source samples, evidence quotes or service credentials are persisted.
    @discardableResult public func create(_ draft: GeneratedTranslationProfile, activate: Bool) throws -> UUID {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        let additions = try draft.catalog(activate: activate)
        guard let sceneID = additions.scenes.first?.id else { throw TranslationProfileFailure.invalid }
        var next = catalog
        next.glossaries += additions.glossaries; next.tones += additions.tones; next.scenes += additions.scenes
        if activate { next.activeSceneID = sceneID }
        try commit(next)
        return sceneID
    }
    private func commit(_ proposed: TranslationProfileCatalog) throws {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        let next = try proposed.validated()
        let data = try JSONEncoder().encode(Saved(catalog: next))
        guard data.count <= TranslationProfilePackage.maximumBytes else { throw TranslationProfileFailure.oversized }
        guard next != catalog || defaults.data(forKey: storageKey) == nil || !issue.isEmpty else { return }
        let changed = next.snapshot != catalog.snapshot
        defaults.set(data, forKey: storageKey)
        catalog = next; issue = ""
        if changed { onChange?() }
    }
}

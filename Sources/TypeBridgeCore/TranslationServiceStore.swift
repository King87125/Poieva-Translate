import Combine
import Foundation
import TypeBridgeCredentialSupport

@MainActor
public protocol TranslationCredentialStore {
    func read(_ id: UUID) throws -> String?
    func prepareForSave(_ id: UUID) async throws -> String?
    func write(_ key: String?, for id: UUID) throws
}

public extension TranslationCredentialStore {
    func prepareForSave(_ id: UUID) async throws -> String? { try read(id) }
}

typealias CredentialVersionMigration = TypeBridgeCredentialSupport.CredentialVersionMigration

@MainActor
public final class KeychainTranslationCredentials: TranslationCredentialStore {
    private var cache: [UUID: String] = [:]
    private var revisions: [UUID: UUID] = [:]
    private var authorizing = false
    private let readItem: @Sendable (UUID, Bool) throws -> String?
    private let writeItem: (String?, UUID) throws -> Void
    public init() {
        readItem = { id, interactive in try CredentialServiceClient.read(id, interactive: interactive) }
        writeItem = { value, id in try CredentialServiceClient.write(value, for: id) }
    }
    init(read: @escaping @Sendable (UUID, Bool) throws -> String?, write: @escaping (String?, UUID) throws -> Void) {
        readItem = read; writeItem = write
    }
    public func read(_ id: UUID) throws -> String? {
        if let value = cache[id] { return value }
        guard !authorizing else { throw ServiceConfigurationFailure.credentialAuthorization }
        let value = try readItem(id, false)
        cache[id] = value
        return value
    }
    /// Prepare/migrate an existing saved key as part of Save, without a separate button.
    public func prepareForSave(_ id: UUID) async throws -> String? {
        if let value = cache[id] { return value }
        guard !authorizing else { throw ServiceConfigurationFailure.busy }
        authorizing = true
        defer { authorizing = false }
        let revision = revisions[id]
        let read = readItem
        let value = try await Task.detached { try read(id, true) }.value
        try Task.checkCancellation()
        guard revisions[id] == revision else { throw CancellationError() }
        cache[id] = value
        return value
    }
    public func write(_ key: String?, for id: UUID) throws {
        guard !authorizing else { throw ServiceConfigurationFailure.busy }
        try writeItem(key, id)
        revisions[id] = UUID()
        cache[id] = key.flatMap { $0.isEmpty ? nil : $0 }
    }
}

@MainActor
public final class TranslationServiceStore: ObservableObject {
    @Published public private(set) var configurations: [TranslationServiceConfiguration] = []
    @Published public private(set) var selectedID: UUID?
    @Published public private(set) var issue = ""
    public var onActiveServiceChange: (() -> Void)?
    public var onConfigurationChange: ((UUID) -> Void)?
    public var canModify: () -> Bool = { true }
    private let defaults: UserDefaults
    private let credentials: any TranslationCredentialStore
    private let storageKey = "translationServices.v1"
    private struct Saved: Codable {
        var configurations: [TranslationServiceConfiguration]
        var selectedID: UUID?
        var keyIDs: Set<UUID>
    }
    private var keyIDs: Set<UUID> = []

    public init(defaults: UserDefaults, credentials: any TranslationCredentialStore) {
        self.defaults = defaults; self.credentials = credentials
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            let valid = try saved.configurations.map { try $0.validated() }
            guard valid.count <= 50, Set(valid.map(\.id)).count == valid.count else { throw ServiceConfigurationFailure.damagedFile }
            configurations = valid
            keyIDs = saved.keyIDs.intersection(Set(valid.map(\.id)))
            selectedID = valid.contains { $0.id == saved.selectedID } ? saved.selectedID : nil
        } catch { issue = L10n.tr("已有服务配置无法读取，已使用苹果系统翻译；原记录未覆盖。") }
    }
    public var activeConfiguration: TranslationServiceConfiguration? { configurations.first { $0.id == selectedID } }
    public var activeName: String { activeConfiguration?.name ?? L10n.tr("苹果系统翻译") }
    public func hasKey(_ id: UUID) -> Bool { keyIDs.contains(id) }
    public func key(for id: UUID) throws -> String? {
        guard keyIDs.contains(id), configurations.contains(where: { $0.id == id }) else { return nil }
        return try credentials.read(id)
    }
    public func prepareCredentialForSave(_ configuration: TranslationServiceConfiguration, key: String, clearKey: Bool) async throws {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        try validateCredentialReuse(configuration, providedKey: key, clearKey: clearKey)
        guard key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !clearKey, hasKey(configuration.id) else { return }
        guard try await credentials.prepareForSave(configuration.id) != nil else { throw ServiceConfigurationFailure.credential }
    }

    public func select(_ id: UUID?) throws {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        guard id == nil || configurations.contains(where: { $0.id == id }) else { throw ServiceConfigurationFailure.invalid(L10n.tr("找不到此服务。")) }
        guard selectedID != id else { return }
        selectedID = id; persist(); onActiveServiceChange?()
    }
    public func save(_ draft: TranslationServiceConfiguration, key: String, clearKey: Bool) throws {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        let configuration = try draft.validated()
        let existing = configurations.first { $0.id == configuration.id }
        guard existing != nil || configurations.count < 50 else { throw ServiceConfigurationFailure.oversized }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateCredentialReuse(configuration, providedKey: key, clearKey: clearKey)
        if clearKey || !key.isEmpty {
            try credentials.write(clearKey ? nil : key, for: configuration.id)
            if clearKey { keyIDs.remove(configuration.id) } else { keyIDs.insert(configuration.id) }
        }
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) { configurations[index] = configuration }
        else { configurations.append(configuration) }
        persist()
        if existing != configuration || !key.isEmpty || clearKey {
            if selectedID == configuration.id { onActiveServiceChange?() }
            else { onConfigurationChange?(configuration.id) }
        }
    }
    public func validateCredentialReuse(_ draft: TranslationServiceConfiguration, providedKey: String, clearKey: Bool) throws {
        if let old = configurations.first(where: { $0.id == draft.id }), old.origin != draft.origin || old.adapter != draft.adapter || old.appID != draft.appID || old.http?.credentialScope != draft.http?.credentialScope,
           hasKey(draft.id), providedKey.isEmpty, !clearKey {
            throw ServiceConfigurationFailure.invalid(L10n.tr("服务类型、地址、应用 ID 或鉴权方式已更改，请重新填写密钥，或选择清除已保存的密钥。"))
        }
    }
    public func remove(_ id: UUID) throws {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        guard configurations.contains(where: { $0.id == id }) else { return }
        if keyIDs.contains(id) { try credentials.write(nil, for: id) }
        let wasActive = selectedID == id
        configurations.removeAll { $0.id == id }; keyIDs.remove(id)
        if wasActive { selectedID = nil }
        persist()
        if wasActive { onActiveServiceChange?() } else { onConfigurationChange?(id) }
    }
    /// Validate the entire package before changing anything; imports never activate or overwrite.
    @discardableResult public func importPackage(_ data: Data) throws -> Int {
        guard canModify() else { throw ServiceConfigurationFailure.busy }
        let incoming = try TranslationServicePackage.decode(data)
        var additions: [TranslationServiceConfiguration] = []
        for configuration in incoming {
            let duplicate = (configurations + additions).contains { old in
                var copy = configuration; copy.id = old.id
                return copy == old
            }
            if !duplicate { additions.append(configuration) }
        }
        guard configurations.count + additions.count <= 50 else { throw ServiceConfigurationFailure.oversized }
        configurations.append(contentsOf: additions); persist()
        return additions.count
    }
    public func exportPackage(ids: Set<UUID>? = nil) throws -> Data {
        let selected = configurations.filter { ids == nil || ids!.contains($0.id) }
        return try TranslationServicePackage.encode(selected)
    }
    private func persist() {
        let saved = Saved(configurations: configurations, selectedID: selectedID, keyIDs: keyIDs)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: storageKey); issue = ""
    }
}

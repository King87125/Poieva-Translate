import Foundation
import Testing
@testable import TypeBridgeCore

private final class CredentialRecorder: @unchecked Sendable {
    let lock = NSLock()
    private var records: [(UUID, Bool)] = []
    var reads: [(UUID, Bool)] { lock.withLock { records } }
    func record(_ id: UUID, _ interactive: Bool) { lock.withLock { records.append((id, interactive)) } }
}

@Suite @MainActor struct CredentialAccessTests {
    @Test func automaticReadsNeverRequestUIAndSuccessfulValuesAreReusedPerService() throws {
        let recorder = CredentialRecorder()
        let credentials = KeychainTranslationCredentials(read: { id, interactive in
            recorder.record(id, interactive)
            return "fixture-key-\(id)"
        }, write: { _, _ in })
        let first = UUID(), second = UUID()
        let original = try credentials.read(first)
        #expect(try credentials.read(first) == original)
        _ = try credentials.read(second)
        #expect(recorder.reads.count == 2 && recorder.reads.allSatisfy { !$0.1 })
        try credentials.write("replacement", for: first)
        #expect(try credentials.read(first) == "replacement" && recorder.reads.count == 2)
        try credentials.write(nil, for: first)
        _ = try credentials.read(first)
        #expect(recorder.reads.count == 3)
        #expect(try credentials.read(second) == "fixture-key-\(second)")
        #expect(recorder.reads.count == 3)
    }

    @Test func savingPreparesExistingKeysAndLaterReadsReuseTheResult() async throws {
        let recorder = CredentialRecorder(), id = UUID()
        let credentials = KeychainTranslationCredentials(read: { id, interactive in
            recorder.record(id, interactive)
            guard interactive else { throw ServiceConfigurationFailure.credentialAuthorization }
            return "authorized-fixture"
        }, write: { _, _ in })
        for _ in 0..<2 {
            #expect(throws: ServiceConfigurationFailure.self) { try credentials.read(id) }
        }
        #expect(try await credentials.prepareForSave(id) == "authorized-fixture")
        #expect(try credentials.read(id) == "authorized-fixture")
        #expect(try await credentials.prepareForSave(id) == "authorized-fixture")
        #expect(recorder.reads.map { $0.1 } == [false, false, true])
    }

    @Test func pendingAuthorizationCannotBlockAutomaticReadsAndCancellationCannotPopulateCache() async throws {
        let recorder = CredentialRecorder(), gate = DispatchSemaphore(value: 0), id = UUID()
        let credentials = KeychainTranslationCredentials(read: { id, interactive in
            recorder.record(id, interactive)
            guard interactive else { throw ServiceConfigurationFailure.credentialAuthorization }
            gate.wait()
            return "late-fixture"
        }, write: { _, _ in })
        let task = Task { try await credentials.prepareForSave(id) }
        defer { gate.signal() }
        for _ in 0..<200 where recorder.reads.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(recorder.reads.count == 1)
        #expect(throws: ServiceConfigurationFailure.self) { try credentials.read(UUID()) }
        #expect(throws: ServiceConfigurationFailure.self) { try credentials.write("new", for: id) }
        #expect(recorder.reads.count == 1)
        task.cancel(); gate.signal()
        do { _ = try await task.value; Issue.record("Cancelled authorization must not cache its result") }
        catch { #expect(error is CancellationError) }
        #expect(throws: ServiceConfigurationFailure.self) { try credentials.read(id) }
        #expect(recorder.reads.map { $0.1 } == [true, false])
    }

    @Test func legacyMigrationWritesReplacementBeforeRetiringOriginalAndPreservesDataOnFailure() throws {
        var operations: [String] = []
        let value = try CredentialVersionMigration.read(wasMigrated: false,
            readCurrent: { nil }, readLegacy: { "legacy-fixture" },
            writeCurrent: { key in #expect(key == "legacy-fixture"); operations.append("write") },
            markMigrated: { operations.append("mark") }, removeLegacy: { operations.append("retire") })
        #expect(value == "legacy-fixture" && operations == ["write", "mark", "retire"])
        operations = []
        #expect(throws: ServiceConfigurationFailure.self) {
            try CredentialVersionMigration.read(wasMigrated: false,
                readCurrent: { nil }, readLegacy: { "legacy-fixture" },
                writeCurrent: { _ in throw ServiceConfigurationFailure.credential },
                markMigrated: { operations.append("mark") }, removeLegacy: { operations.append("retire") })
        }
        #expect(operations.isEmpty)
    }

    @Test func currentKeysWinAndClearedMigratedKeysNeverFallBackToOldCopies() throws {
        var legacyReads = 0, writes = 0, marks = 0
        let current = try CredentialVersionMigration.read(wasMigrated: false,
            readCurrent: { "current-fixture" }, readLegacy: { legacyReads += 1; return "stale-fixture" },
            writeCurrent: { _ in writes += 1 }, markMigrated: { marks += 1 }, removeLegacy: {})
        #expect(current == "current-fixture" && legacyReads == 0 && writes == 0 && marks == 1)
        let removed = try CredentialVersionMigration.read(wasMigrated: true,
            readCurrent: { nil }, readLegacy: { legacyReads += 1; return "stale-fixture" },
            writeCurrent: { _ in writes += 1 }, markMigrated: { marks += 1 }, removeLegacy: {})
        #expect(removed == nil && legacyReads == 0 && writes == 0 && marks == 1)
    }

    @Test func savingOnlyPreparesRetainedCredentialsAfterScopeValidation() async throws {
        let suite = "TypeBridge.SaveMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = SaveCredentialStub()
        let store = TranslationServiceStore(defaults: defaults, credentials: keys)
        let configuration = TranslationServiceConfiguration(name: "Test", baseURL: "https://api.example.com/v1", model: "test")
        try store.save(configuration, key: "original-fixture", clearKey: false)
        try await store.prepareCredentialForSave(configuration, key: "", clearKey: false)
        #expect(keys.preparations == 1 && store.hasKey(configuration.id))
        try await store.prepareCredentialForSave(configuration, key: "new-fixture", clearKey: false)
        try await store.prepareCredentialForSave(configuration, key: "", clearKey: true)
        #expect(keys.preparations == 1)
        var changed = configuration; changed.baseURL = "https://another.example.com/v1"
        await #expect(throws: ServiceConfigurationFailure.self) {
            try await store.prepareCredentialForSave(changed, key: "", clearKey: false)
        }
        #expect(keys.preparations == 1 && store.configurations == [configuration])
        keys.unavailable = true
        await #expect(throws: ServiceConfigurationFailure.self) {
            try await store.prepareCredentialForSave(configuration, key: "", clearKey: false)
        }
        #expect(store.hasKey(configuration.id) && store.configurations == [configuration])
    }
}

@MainActor private final class SaveCredentialStub: TranslationCredentialStore {
    var values: [UUID: String] = [:]
    var preparations = 0
    var unavailable = false
    func read(_ id: UUID) throws -> String? { values[id] }
    func write(_ key: String?, for id: UUID) throws { values[id] = key }
    func prepareForSave(_ id: UUID) async throws -> String? {
        preparations += 1
        if unavailable { throw ServiceConfigurationFailure.credential }
        return values[id]
    }
}

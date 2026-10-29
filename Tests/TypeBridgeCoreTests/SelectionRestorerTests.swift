import Testing
@testable import TypeBridgeCore

@MainActor
struct SelectionRestorerTests {
    private let caret = TextSelection(location: 4, length: 0)
    private let whole = TextSelection(location: 0, length: 12)

    @Test func waitsForDelayedEditorAcknowledgmentBeforeReturning() async throws {
        var actual = whole
        var sets = 0
        var waits = 0
        let restored = try await SelectionRestorer.restore(original: caret, temporary: whole,
            isFocused: { true }, current: { actual }, canSet: { true },
            set: { range in sets += 1; #expect(range == caret); return true },
            wait: { waits += 1; if waits == 2 { actual = caret } })
        #expect(restored)
        #expect(actual == caret)
        #expect(sets == 1)
        #expect(waits == 2)
    }

    @Test func anAlreadyRestoredCaretNeverGetsMovedAgain() async throws {
        var sets = 0
        let restored = try await SelectionRestorer.restore(original: caret, temporary: whole,
            isFocused: { true }, current: { caret }, canSet: { true },
            set: { _ in sets += 1; return true }, wait: {})
        #expect(restored)
        #expect(sets == 0)
    }

    @Test func neverOverwritesAUserSelectionMadeBeforeCleanup() async {
        var sets = 0
        do {
            _ = try await SelectionRestorer.restore(original: caret, temporary: whole,
                isFocused: { true }, current: { TextSelection(location: 7, length: 2) }, canSet: { true },
                set: { _ in sets += 1; return true }, wait: {})
            Issue.record("A changed selection must be refused")
        } catch { #expect(error as? SelectionRestorationFailure == .selectionChanged) }
        #expect(sets == 0)
    }

    @Test func userMovementWhileWaitingStopsWithoutAnotherSet() async {
        var actual = whole
        var sets = 0
        do {
            _ = try await SelectionRestorer.restore(original: caret, temporary: whole,
                isFocused: { true }, current: { actual }, canSet: { true },
                set: { _ in sets += 1; return true },
                wait: { actual = TextSelection(location: 8, length: 0) })
            Issue.record("Movement while waiting must be refused")
        } catch { #expect(error as? SelectionRestorationFailure == .selectionChanged) }
        #expect(sets == 1)
        #expect(actual == TextSelection(location: 8, length: 0))
    }

    @Test func acceptedSetWithoutAcknowledgmentIsNotReportedAsRestored() async {
        var waits = 0
        do {
            _ = try await SelectionRestorer.restore(original: caret, temporary: whole,
                isFocused: { true }, current: { whole }, canSet: { true }, set: { _ in true },
                wait: { waits += 1 })
            Issue.record("A successful setter is not confirmation")
        } catch { #expect(error as? SelectionRestorationFailure == .notRestored) }
        #expect(waits == 6)
    }

    @Test func focusLossDoesNotRestoreIntoAnotherTarget() async {
        var sets = 0
        do {
            _ = try await SelectionRestorer.restore(original: caret, temporary: whole,
                isFocused: { false }, current: { whole }, canSet: { true },
                set: { _ in sets += 1; return true }, wait: {})
            Issue.record("A different focus must be refused")
        } catch { #expect(error as? SelectionRestorationFailure == .focusChanged) }
        #expect(sets == 0)
    }

    @Test func unsupportedSetterLeavesTheKnownTemporarySelectionAlone() async throws {
        var sets = 0
        let restored = try await SelectionRestorer.restore(original: caret, temporary: whole,
            isFocused: { true }, current: { whole }, canSet: { false },
            set: { _ in sets += 1; return true }, wait: {})
        #expect(!restored)
        #expect(sets == 0)
    }

    @Test func cancelledTranslationCanStillFinishSafeSelectionCleanup() async throws {
        var actual = whole
        let task = Task { @MainActor in
            try await SelectionRestorer.restore(original: caret, temporary: whole,
                isFocused: { true }, current: { actual }, canSet: { true }, set: { _ in true },
                wait: { actual = caret })
        }
        task.cancel()
        #expect(try await task.value)
        #expect(actual == caret)
    }
}

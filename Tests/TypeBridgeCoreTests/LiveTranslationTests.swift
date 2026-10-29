import AppKit
import Testing
@testable import TypeBridgeCore

@MainActor
private final class TestDelay {
    var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func release() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
private final class PendingProvider: TranslationProvider {
    let name = "Test"
    var requests: [TranslationRequest] = []
    var handlers: [TranslationProgressHandler?] = []
    var pending: [Int: CheckedContinuation<String, Error>] = [:]
    var cancellationCount = 0
    func translate(_ request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> String {
        let index = requests.count
        requests.append(request)
        handlers.append(progress)
        // Intentionally ignore cancellation to exercise late provider replies.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func translateSegments(_ texts: [String], for request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> [String] { [] }
    func cancel() { cancellationCount += 1 }
    func complete(_ index: Int, with text: String) { pending.removeValue(forKey: index)?.resume(returning: text) }
    func finishAll() { for index in Array(pending.keys) { complete(index, with: "Done") } }
}

@MainActor
private final class LiveEvents {
    var clears = 0
    var starts = 0
    var cancellations = 0
    var results: [String] = []
    var progress: [TranslationProgress] = []
    var errors: [Error] = []
    func receive(_ event: LiveTranslationController.Event) {
        switch event {
        case .cleared: clears += 1
        case .started: starts += 1
        case .cancelled: cancellations += 1
        case let .completed(text, _): results.append(text)
        case let .progress(value): progress.append(value)
        case let .failed(error): errors.append(error)
        case .target: break
        }
    }
}

@MainActor
struct LiveTranslationTests {
    private func input(_ text: String, target: AppLanguage = .english) -> WorkbenchTranslationInput {
        WorkbenchTranslationInput(text: text, direction: .fixedTarget, source: .automatic, target: target, preserveCode: true)
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test func burstOfEditsWaitsAndOnlyTranslatesLatestText() async {
        let provider = PendingProvider(), delay = TestDelay(), events = LiveEvents()
        let controller = LiveTranslationController(provider: provider, wait: { await delay.wait() })
        controller.onEvent = events.receive
        defer { controller.suspend(); delay.release(); provider.finishAll() }
        controller.update(input("你"), isComposing: false)
        #expect(await eventually { delay.continuations.count == 1 })
        #expect(provider.requests.isEmpty)
        controller.update(input("你好"), isComposing: false)
        #expect(await eventually { delay.continuations.count == 2 })
        delay.release()
        #expect(await eventually { provider.requests.count == 1 })
        #expect(provider.requests.first?.text == "你好")
        provider.complete(0, with: "Hello")
        #expect(await eventually { events.results == ["Hello"] })
        #expect(events.starts == 1)
    }

    @Test func compositionCancelsPendingWorkAndOnlyCommittedChineseIsTranslated() async {
        let provider = PendingProvider(), delay = TestDelay(), events = LiveEvents()
        let controller = LiveTranslationController(provider: provider, wait: { await delay.wait() })
        controller.onEvent = events.receive
        defer { controller.suspend(); delay.release(); provider.finishAll() }
        controller.update(input("你"), isComposing: false)
        #expect(await eventually { delay.continuations.count == 1 })
        controller.update(input("你hao"), isComposing: true)
        controller.translateNow(input("你hao"), isComposing: true)
        delay.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(provider.requests.isEmpty)
        #expect(events.starts == 0)
        controller.update(input("你好"), isComposing: false)
        #expect(await eventually { delay.continuations.count == 1 })
        delay.release()
        #expect(await eventually { provider.requests.count == 1 })
        #expect(provider.requests.first?.text == "你好")
    }

    @Test func editingDuringTranslationRejectsLateResultAndProgress() async {
        let provider = PendingProvider(), delay = TestDelay(), events = LiveEvents()
        let controller = LiveTranslationController(provider: provider, wait: { await delay.wait() })
        controller.onEvent = events.receive
        defer { controller.suspend(); delay.release(); provider.finishAll() }
        controller.translateNow(input("旧文本"), isComposing: false)
        #expect(await eventually { provider.requests.count == 1 })
        controller.update(input("新文本"), isComposing: false)
        provider.handlers[0]?(TranslationProgress(completedCharacters: 3, totalCharacters: 3))
        provider.complete(0, with: "Old result")
        #expect(await eventually { delay.continuations.count == 1 })
        delay.release()
        #expect(await eventually { provider.requests.count == 2 })
        provider.complete(1, with: "New result")
        #expect(await eventually { events.results == ["New result"] })
        #expect(events.progress.isEmpty)
        #expect(provider.cancellationCount >= 1)
    }

    @Test func clearingOrWhitespaceCancelsWithoutShowingOldTranslationAgain() async {
        let provider = PendingProvider(), events = LiveEvents()
        let controller = LiveTranslationController(provider: provider)
        controller.onEvent = events.receive
        defer { controller.suspend(); provider.finishAll() }
        controller.translateNow(input("你好"), isComposing: false)
        #expect(await eventually { provider.requests.count == 1 })
        controller.update(input(""), isComposing: false)
        controller.update(input(" \n\t"), isComposing: false)
        provider.complete(0, with: "Hello")
        for _ in 0..<10 { await Task.yield() }
        #expect(events.results.isEmpty)
        #expect(events.clears == 3)
        #expect(provider.requests.count == 1)
    }

    @Test func manualActionBypassesDebounceAndReplacesPendingAutomaticRequest() async {
        let provider = PendingProvider(), delay = TestDelay()
        let controller = LiveTranslationController(provider: provider, wait: { await delay.wait() })
        defer { controller.suspend(); delay.release(); provider.finishAll() }
        controller.update(input("你好"), isComposing: false)
        #expect(await eventually { delay.continuations.count == 1 })
        controller.translateNow(input("你好"), isComposing: false)
        #expect(await eventually { provider.requests.count == 1 })
        delay.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(provider.requests.count == 1)
    }

    @Test func changingLanguageUsesLatestConfigurationSnapshot() async {
        let provider = PendingProvider(), delay = TestDelay()
        let controller = LiveTranslationController(provider: provider, wait: { await delay.wait() })
        defer { controller.suspend(); delay.release(); provider.finishAll() }
        controller.update(input("Hello"), isComposing: false)
        #expect(await eventually { delay.continuations.count == 1 })
        var latest = input("Hello", target: .japanese)
        latest.source = .english
        latest.preserveCode = false
        controller.update(latest, isComposing: false)
        #expect(await eventually { delay.continuations.count == 2 })
        delay.release()
        #expect(await eventually { provider.requests.count == 1 })
        #expect(provider.requests.first?.source == .english)
        #expect(provider.requests.first?.target == .japanese)
        #expect(provider.requests.first?.preserveCode == false)
    }

    @Test func cancelledDebounceNeverStartsAndCannotCancelLaterExternalWork() async {
        let provider = PendingProvider(), delay = TestDelay(), events = LiveEvents()
        let controller = LiveTranslationController(provider: provider, wait: { await delay.wait() })
        controller.onEvent = events.receive
        defer { controller.suspend(); delay.release(); provider.finishAll() }
        controller.update(input("你好"), isComposing: false)
        #expect(await eventually { delay.continuations.count == 1 })
        controller.cancel()
        let count = provider.cancellationCount
        controller.suspend()
        delay.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(provider.requests.isEmpty)
        #expect(events.cancellations == 1)
        #expect(provider.cancellationCount == count)
    }

    @Test func longInputFailsWithoutCallingService() async {
        let provider = PendingProvider(), events = LiveEvents()
        let controller = LiveTranslationController(provider: provider)
        controller.onEvent = events.receive
        defer { controller.suspend(); provider.finishAll() }
        controller.translateNow(input(String(repeating: "字", count: 20_001)), isComposing: false)
        #expect(await eventually { events.errors.count == 1 })
        #expect(provider.requests.isEmpty)
        #expect(events.starts == 1)
    }
}

@MainActor
struct WorkbenchTextViewTests {
    private func editor() -> WorkbenchTextView {
        let editor = WorkbenchTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        editor.isRichText = false
        return editor
    }

    @Test func composingHidesPlaceholderAndModelRefreshCannotErasePinyin() {
        let editor = editor()
        #expect(editor.showsPlaceholder)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!editor.showsPlaceholder)
        editor.applyModelText("")
        #expect(editor.string == "ni")
        #expect(editor.hasMarkedText())
    }

    @Test func committingChineseReportsFinalTextAndCompositionEnded() {
        let editor = editor()
        var changes: [(String, Bool)] = []
        editor.onEditingChange = { changes.append(($0, $1)) }
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "你")
        #expect(!editor.hasMarkedText())
        #expect(!editor.showsPlaceholder)
        #expect(changes.last?.0 == "你")
        #expect(changes.last?.1 == false)
        #expect(changes.contains { $0.1 })
    }

    @Test func clearDuringCompositionRestoresPlaceholderWithoutResubmittingDraft() {
        let editor = editor()
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        var changes = 0
        editor.onEditingChange = { _, _ in changes += 1 }
        editor.applyModelText("", replacingComposition: true)
        #expect(editor.string.isEmpty)
        #expect(!editor.hasMarkedText())
        #expect(editor.showsPlaceholder)
        #expect(changes == 0)
    }

    @Test func programmaticTextDoesNotCauseAutomaticTranslationOrMoveCaretOnRefresh() {
        let editor = editor()
        var changes = 0
        editor.onEditingChange = { _, _ in changes += 1 }
        editor.applyModelText("Hello")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.applyModelText("Hello")
        #expect(!editor.showsPlaceholder)
        #expect(editor.selectedRange().location == 2)
        #expect(changes == 0)
    }
}

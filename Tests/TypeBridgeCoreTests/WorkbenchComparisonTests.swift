import Foundation
import Testing
@testable import TypeBridgeCore

@MainActor
private final class ComparisonProvider: TranslationProvider {
    let name = "Fixture"
    var requests: [TranslationRequest] = []
    var callbacks: [TranslationProgressHandler?] = []
    var continuations: [Int: CheckedContinuation<String, Error>] = [:]
    var cancellations = 0
    func translate(_ request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> String {
        let index = requests.count; requests.append(request); callbacks.append(progress)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func translateSegments(_ texts: [String], for request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> [String] { [] }
    func cancel() { cancellations += 1 }
    func succeed(_ index: Int, _ text: String) { continuations.removeValue(forKey: index)?.resume(returning: text) }
    func fail(_ index: Int) { continuations.removeValue(forKey: index)?.resume(throwing: RemoteTranslationFailure.status(401)) }
    func finish() { for index in Array(continuations.keys) { succeed(index, "Finished") } }
}

@MainActor
private final class ComparisonDelay {
    var waits: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waits.append($0) } }
    func release() { let pending = waits; waits = []; pending.forEach { $0.resume() } }
}

@MainActor
struct WorkbenchComparisonTests {
    private let choices = [WorkbenchServiceChoice(id: "one", name: "服务一"), WorkbenchServiceChoice(id: "two", name: "服务二")]
    private func input(_ text: String = "Hello", target: AppLanguage = .simplifiedChinese) -> WorkbenchTranslationInput {
        .init(text: text, direction: .fixedTarget, source: .english, target: target, preserveCode: true)
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(1)) }; return condition()
    }
    @Test func resultsArriveIndependentlyAndKeepTheChosenOrder() async {
        let first = ComparisonProvider(), second = ComparisonProvider()
        let controller = WorkbenchComparisonController(makeProvider: { $0 == "one" ? first : second })
        defer { controller.suspend(); first.finish(); second.finish() }
        controller.configure(choices); controller.update(input(), isComposing: false, immediately: true)
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        second.succeed(0, "第二译文")
        #expect(await eventually { controller.results[1].text == "第二译文" })
        #expect(controller.isTranslating && controller.results[0].text.isEmpty)
        first.succeed(0, "第一译文")
        #expect(await eventually { !controller.isTranslating })
        #expect(controller.results.map(\.id) == ["one", "two"])
        #expect(controller.results.map(\.text) == ["第一译文", "第二译文"])
    }
    @Test func oneFailureDoesNotEraseSuccessAndRetryOnlyCallsThatService() async {
        let first = ComparisonProvider(), second = ComparisonProvider()
        let controller = WorkbenchComparisonController(makeProvider: { $0 == "one" ? first : second })
        defer { controller.suspend(); first.finish(); second.finish() }
        controller.configure(choices); controller.update(input(), isComposing: false, immediately: true)
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        first.succeed(0, "成功译文"); second.fail(0)
        #expect(await eventually { controller.results[1].phase == .failed })
        #expect(controller.results[0].text == "成功译文")
        #expect(controller.results[1].error == RemoteTranslationFailure.status(401).localizedDescription)
        controller.retry("two", input: input(), isComposing: false)
        #expect(await eventually { second.requests.count == 2 })
        #expect(first.requests.count == 1 && controller.results[0].text == "成功译文")
        second.succeed(1, "重试译文")
        #expect(await eventually { controller.results[1].text == "重试译文" })
    }
    @Test func editsAndLateProgressCannotMixTwoInputSnapshots() async {
        let first = ComparisonProvider(), second = ComparisonProvider()
        let controller = WorkbenchComparisonController(makeProvider: { $0 == "one" ? first : second })
        defer { controller.suspend(); first.finish(); second.finish() }
        controller.configure(choices); controller.update(input("Old"), isComposing: false, immediately: true)
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        controller.update(input("New", target: .japanese), isComposing: false, immediately: true)
        #expect(await eventually { first.requests.count == 2 && second.requests.count == 2 })
        first.callbacks[0]?(TranslationProgress(completedCharacters: 999, totalCharacters: 999))
        first.succeed(0, "Old first"); second.succeed(0, "Old second")
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.results.allSatisfy { $0.text.isEmpty && $0.progress == nil })
        first.succeed(1, "新しい一"); second.succeed(1, "新しい二")
        #expect(await eventually { controller.results.allSatisfy { $0.phase == .completed } })
        #expect(controller.results.map(\.language) == [.japanese, .japanese])
        #expect(first.requests.last?.text == "New" && second.requests.last?.text == "New")
    }
    @Test func cancelKeepsCompletedCardsAndRejectsTheRemainingLateReply() async {
        let first = ComparisonProvider(), second = ComparisonProvider()
        let controller = WorkbenchComparisonController(makeProvider: { $0 == "one" ? first : second })
        defer { controller.suspend(); first.finish(); second.finish() }
        controller.configure(choices); controller.update(input(), isComposing: false, immediately: true)
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        first.succeed(0, "保留译文")
        #expect(await eventually { controller.results[0].phase == .completed })
        controller.suspend(); second.succeed(0, "迟到译文")
        for _ in 0..<10 { await Task.yield() }
        #expect(!controller.isTranslating)
        #expect(controller.results[0].text == "保留译文" && controller.results[1].text.isEmpty)
    }
    @Test func reconfigurationRejectsRemovedServicesAndSameIDOldInstances() async {
        let old = ComparisonProvider(), replacement = ComparisonProvider(), other = ComparisonProvider()
        var replacing = false
        let controller = WorkbenchComparisonController(makeProvider: { id in id == "one" ? (replacing ? replacement : old) : other })
        defer { controller.suspend(); old.finish(); replacement.finish(); other.finish() }
        controller.configure(choices); controller.update(input(), isComposing: false, immediately: true)
        #expect(await eventually { old.requests.count == 1 && other.requests.count == 1 })
        replacing = true
        controller.configure([choices[0]], force: true); controller.update(input(), isComposing: false, immediately: true)
        #expect(await eventually { replacement.requests.count == 1 })
        old.succeed(0, "Old same ID"); other.succeed(0, "Removed service")
        replacement.succeed(0, "New service")
        #expect(await eventually { controller.results.first?.text == "New service" })
        #expect(controller.results.count == 1 && controller.results.first?.id == "one")
    }
    @Test func composingAndClearCancelEveryPendingDebounceWithoutRequests() async {
        let first = ComparisonProvider(), second = ComparisonProvider(), delay = ComparisonDelay()
        let controller = WorkbenchComparisonController(makeProvider: { $0 == "one" ? first : second }, wait: { await delay.wait() })
        defer { controller.suspend(); delay.release(); first.finish(); second.finish() }
        controller.configure(choices); controller.update(input(), isComposing: false)
        #expect(await eventually { delay.waits.count == 2 })
        controller.update(input("ni"), isComposing: true); delay.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(first.requests.isEmpty && second.requests.isEmpty)
        controller.update(input("你好"), isComposing: false, immediately: true)
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        controller.update(input(""), isComposing: false)
        first.succeed(0, "Old"); second.succeed(0, "Old")
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.results.allSatisfy { $0.text.isEmpty && $0.error.isEmpty && $0.phase == .idle })
    }
    @Test func duplicateSelectionsAreDeduplicatedWithoutLimitingCountAndUnchangedConfigurationDoesNotRestart() {
        let provider = ComparisonProvider(); var builds = 0
        let controller = WorkbenchComparisonController(makeProvider: { _ in builds += 1; return provider })
        defer { controller.suspend(); provider.finish() }
        let all = (0..<51).map { WorkbenchServiceChoice(id: String($0), name: String($0)) }
        #expect(controller.configure([all[0]] + all))
        #expect(controller.results.map(\.id) == all.map(\.id) && builds == 51)
        #expect(!controller.configure(all) && builds == 51)
    }
    @Test func oversizedInputFailsEachCardWithoutCallingAnyService() async {
        let first = ComparisonProvider(), second = ComparisonProvider()
        let controller = WorkbenchComparisonController(makeProvider: { $0 == "one" ? first : second })
        defer { controller.suspend(); first.finish(); second.finish() }
        controller.configure(choices); controller.update(input(String(repeating: "a", count: 20_001)), isComposing: false, immediately: true)
        #expect(await eventually { controller.results.allSatisfy { $0.phase == .failed } })
        #expect(first.requests.isEmpty && second.requests.isEmpty)
    }
    @Test func everySelectedServiceBeyondFourReceivesTheRequest() async {
        let all = (0..<7).map { WorkbenchServiceChoice(id: String($0), name: "服务\($0)") }
        let providers = all.map { _ in ComparisonProvider() }
        let controller = WorkbenchComparisonController(makeProvider: { providers[Int($0)!] })
        defer { controller.suspend(); providers.forEach { $0.finish() } }
        controller.configure(all); controller.update(input(), isComposing: false, immediately: true)
        #expect(await eventually { providers.allSatisfy { $0.requests.count == 1 } })
        for index in providers.indices.reversed() { providers[index].succeed(0, "译文\(index)") }
        #expect(await eventually { controller.results.allSatisfy { $0.phase == .completed } })
        #expect(controller.results.map(\.text) == providers.indices.map { "译文\($0)" })
    }
    @Test func deselectingEveryServiceCancelsAndRejectsLateReplies() async {
        let first = ComparisonProvider(), second = ComparisonProvider()
        let controller = WorkbenchComparisonController(makeProvider: { $0 == "one" ? first : second })
        defer { controller.suspend(); first.finish(); second.finish() }
        controller.configure(choices); controller.update(input(), isComposing: false, immediately: true)
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        #expect(controller.configure([]))
        first.succeed(0, "迟到译文一"); second.succeed(0, "迟到译文二")
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.results.isEmpty && !controller.isTranslating)
        #expect(first.cancellations > 0 && second.cancellations > 0)
    }
}

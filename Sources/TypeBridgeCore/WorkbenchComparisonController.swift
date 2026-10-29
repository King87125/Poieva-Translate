import Combine
import Foundation

public struct WorkbenchServiceChoice: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct WorkbenchServiceResult: Identifiable {
    public enum Phase { case idle, translating, completed, failed }
    public var id: String { service.id }
    public let service: WorkbenchServiceChoice
    public var phase: Phase = .idle
    public var text = ""
    public var language: AppLanguage?
    public var error = ""
    public var progress: TranslationProgress?
    public var startedAt = Date()
}

/// Each selected service owns its own debounce/cancellation state and publishes independently.
/// A cohort token also prevents a removed or reconfigured service from publishing a late reply.
@MainActor
public final class WorkbenchComparisonController: ObservableObject {
    @Published public private(set) var results: [WorkbenchServiceResult] = []
    public var onChange: (() -> Void)?
    private var controllers: [String: LiveTranslationController] = [:]
    private let makeProvider: @MainActor (String) -> any TranslationProvider
    private let wait: @MainActor () async throws -> Void
    private var cohort = UUID()
    public var isTranslating: Bool { results.contains { $0.phase == .translating } }
    public var choices: [WorkbenchServiceChoice] { results.map(\.service) }

    public init(makeProvider: @escaping @MainActor (String) -> any TranslationProvider,
                wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(550)) }) {
        self.makeProvider = makeProvider; self.wait = wait
    }
    @discardableResult public func configure(_ choices: [WorkbenchServiceChoice], force: Bool = false) -> Bool {
        var seen = Set<String>()
        let choices = choices.filter { seen.insert($0.id).inserted }
        guard force || choices != self.choices else { return false }
        cohort = UUID()
        controllers.values.forEach { $0.suspend() }; controllers = [:]
        results = choices.map { WorkbenchServiceResult(service: $0) }
        let generation = cohort
        for choice in choices {
            let controller = LiveTranslationController(provider: makeProvider(choice.id), wait: wait)
            controller.onEvent = { [weak self] event in
                guard let self, self.cohort == generation, let index = self.results.firstIndex(where: { $0.id == choice.id }) else { return }
                switch event {
                case .cleared: self.results[index] = WorkbenchServiceResult(service: choice)
                case .started:
                    self.results[index].phase = .translating; self.results[index].startedAt = Date()
                case let .target(language): self.results[index].language = language
                case let .progress(progress): self.results[index].progress = progress
                case let .completed(text, language):
                    self.results[index].text = text; self.results[index].language = language; self.results[index].phase = .completed
                case let .failed(error):
                    self.results[index].error = error.localizedDescription; self.results[index].phase = .failed
                case .cancelled:
                    if self.results[index].phase == .translating { self.results[index].phase = .idle }
                }
                self.onChange?()
            }
            controllers[choice.id] = controller
        }
        onChange?()
        return true
    }
    public func update(_ input: WorkbenchTranslationInput, isComposing: Bool, immediately: Bool = false) {
        for result in results {
            if immediately { controllers[result.id]?.translateNow(input, isComposing: isComposing) }
            else { controllers[result.id]?.update(input, isComposing: isComposing) }
        }
    }
    public func retry(_ id: String, input: WorkbenchTranslationInput, isComposing: Bool) {
        controllers[id]?.translateNow(input, isComposing: isComposing)
    }
    public func suspend(clearResults: Bool = false) {
        controllers.values.forEach { $0.suspend() }
        for index in results.indices {
            if clearResults { results[index] = WorkbenchServiceResult(service: results[index].service) }
            else if results[index].phase == .translating { results[index].phase = .idle }
        }
        onChange?()
    }
}

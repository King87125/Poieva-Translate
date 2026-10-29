import Foundation

public struct WorkbenchTranslationInput: Equatable, Sendable {
    public var text: String
    public var direction: TranslationDirection
    public var source: AppLanguage
    public var target: AppLanguage
    public var preserveCode: Bool
    public var guidance: TranslationGuidance?

    public init(text: String, direction: TranslationDirection, source: AppLanguage,
                target: AppLanguage, preserveCode: Bool, guidance: TranslationGuidance? = nil) {
        self.text = text
        self.direction = direction
        self.source = source
        self.target = target
        self.preserveCode = preserveCode
        self.guidance = guidance
    }
}

/// A workbench request belongs to one committed text/configuration snapshot.
/// Editing, IME composition, clearing and external shortcut work invalidate it.
@MainActor
public final class LiveTranslationController {
    public enum Event {
        case cleared, started, cancelled
        case target(AppLanguage)
        case progress(TranslationProgress)
        case completed(String, AppLanguage)
        case failed(Error)
    }

    public var onEvent: ((Event) -> Void)?
    private let provider: any TranslationProvider
    private let wait: @MainActor () async throws -> Void
    private var operation: Task<Void, Never>?
    private var revision = UUID()

    public init(provider: any TranslationProvider,
                wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(550)) }) {
        self.provider = provider
        self.wait = wait
    }

    public func update(_ input: WorkbenchTranslationInput, isComposing: Bool) {
        submit(input, isComposing: isComposing, immediately: false)
    }

    public func translateNow(_ input: WorkbenchTranslationInput, isComposing: Bool) {
        submit(input, isComposing: isComposing, immediately: true)
    }

    public func suspend() { invalidate() }

    public func cancel() {
        let hadWork = operation != nil
        invalidate()
        if hadWork { onEvent?(.cancelled) }
    }

    private func invalidate() {
        revision = UUID()
        if let operation {
            operation.cancel()
            provider.cancel()
        }
        operation = nil
    }

    private func submit(_ input: WorkbenchTranslationInput, isComposing: Bool, immediately: Bool) {
        invalidate()
        onEvent?(.cleared)
        guard !isComposing, !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = revision
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == id { self.operation = nil } }
            do {
                if !immediately { try await self.wait() }
                try Task.checkCancellation()
                guard self.revision == id else { return }
                self.onEvent?(.started)
                guard input.text.count <= 20_000 else { throw TranslationFailure.tooLong }
                var request = try input.direction.request(text: input.text,
                    source: input.direction == .chineseEnglish ? .automatic : input.source,
                    fixedTarget: input.target, preserveCode: input.preserveCode)
                request.guidance = input.guidance
                try Task.checkCancellation()
                guard self.revision == id else { return }
                self.onEvent?(.target(request.target))
                let result = try await self.provider.translate(request, progress: { [weak self] progress in
                    guard let self, self.revision == id, !Task.isCancelled else { return }
                    self.onEvent?(.progress(progress))
                })
                try Task.checkCancellation()
                guard self.revision == id else { return }
                self.onEvent?(.completed(result, request.target))
            } catch {
                guard self.revision == id, !Task.isCancelled else { return }
                self.onEvent?(error is CancellationError ? .cancelled : .failed(error))
            }
        }
    }
}

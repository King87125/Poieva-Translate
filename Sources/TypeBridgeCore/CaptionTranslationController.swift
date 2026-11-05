import Combine
import Foundation

public struct CaptionLine: Equatable, Identifiable, Sendable {
    public let id: String
    public var source = ""
    public var translation = ""
    public var isFinal = false
    public var channel = ""
    public init(id: String, source: String = "", translation: String = "", isFinal: Bool = false, channel: String = "") {
        self.id = id; self.source = source; self.translation = translation; self.isFinal = isFinal; self.channel = channel
    }
}

/// Correlates socket events by item ID, including late completions. Display and
/// translation are bounded; no transcript is persisted and no translation retries automatically.
@MainActor
public final class CaptionTranslationController: ObservableObject {
    @Published public private(set) var lines: [CaptionLine] = []
    @Published public private(set) var error = ""
    public var onFailure: ((Error) -> Void)?
    public var onIdle: (() -> Void)?
    private var provider: (any TranslationProvider)?
    private var request: ((String, String) throws -> TranslationRequest)?
    private var pending: [String] = []
    private var completedIDs: [String] = []
    private var task: Task<Void, Never>?
    private var revision = UUID()
    public init() {}
    public func start(provider: any TranslationProvider, request: @escaping (String, String) throws -> TranslationRequest) {
        stop(clear: true); self.provider = provider; self.request = request; error = ""
    }
    public func receive(_ event: CaptionTranscriptEvent, channel: String = "") throws {
        guard provider != nil else { return }
        if event == .finished { return }
        let id: String
        switch event { case .committed(let value, _), .delta(let value, _), .snapshot(let value, _), .completed(let value, _): id = value; case .finished: return }
        if case .committed = event {} else if completedIDs.contains(id) { return }
        if !lines.contains(where: { $0.id == id }) {
            guard lines.count < 24 || lines.first?.translation.isEmpty == false else { throw CaptionFailure.backlog }
            if lines.count == 24 { lines.removeFirst() }
            lines.append(.init(id: id, channel: channel))
        }
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .committed(_, let previous):
            if previous == id { throw CaptionFailure.response }
            // The server may complete turns in another order. Anchor the row to
            // the committed predecessor rather than moving whichever row is newest.
            if let previous, let old = lines.firstIndex(where: { $0.id == previous }), old > index {
                let line = lines.remove(at: index)
                if let parent = lines.firstIndex(where: { $0.id == previous }) { lines.insert(line, at: parent + 1) }
            }
        case .delta(_, let text):
            guard !lines[index].isFinal, lines[index].source.count + text.count <= 4_000 else { throw CaptionFailure.response }
            lines[index].source += text
        case .snapshot(_, let text):
            guard !lines[index].isFinal, text.count <= 4_000 else { throw CaptionFailure.response }
            lines[index].source = text
        case .completed(_, let text):
            guard !lines[index].isFinal else { return }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 4_000, pending.count < 8 else { throw CaptionFailure.backlog }
            lines[index].source = text; lines[index].isFinal = true
            completedIDs.append(id); if completedIDs.count > 128 { completedIDs.removeFirst() }
            if !text.isEmpty { pending.append(id); process() }
        case .finished: break
        }
    }
    private func process() {
        guard task == nil, !pending.isEmpty, let provider, let request else { return }
        let id = pending.removeFirst(), generation = revision
        guard let index = lines.firstIndex(where: { $0.id == id }) else { process(); return }
        let source = lines[index].source
        let before = lines[..<index].filter(\.isFinal).map(\.source).joined(separator: "\n")
        task = Task { @MainActor [weak self] in
            do {
                let result = try await provider.translate(request(source, before), progress: nil)
                try Task.checkCancellation()
                guard let self, self.revision == generation else { return }
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationFailure.incompleteResponse }
                if let row = self.lines.firstIndex(where: { $0.id == id }) { self.lines[row].translation = result }
                self.task = nil
                if self.pending.isEmpty { self.onIdle?() } else { self.process() }
            } catch {
                guard let self, self.revision == generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.stop(clear: false); self.onFailure?(error)
            }
        }
    }
    public func stop(clear: Bool = false) {
        revision = UUID(); task?.cancel(); task = nil; provider?.cancel(); provider = nil; request = nil; pending = []
        if clear { lines = []; completedIDs = []; error = "" }
    }
    public func showSample(_ values: [CaptionLine]) { stop(clear: true); lines = Array(values.suffix(24)) }
}

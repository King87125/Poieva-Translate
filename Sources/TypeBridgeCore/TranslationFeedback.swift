import Foundation

public enum FeedbackStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case waves, typewriter, spinner, characterCount
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .waves: return L10n.tr("波浪圆点")
        case .typewriter: return L10n.tr("打字机")
        case .spinner: return L10n.tr("简洁加载")
        case .characterCount: return L10n.tr("翻译字数")
        }
    }
}

public struct TranslationProgress: Equatable, Sendable {
    public let completedCharacters: Int
    public let totalCharacters: Int
    public init(completedCharacters: Int, totalCharacters: Int) {
        self.totalCharacters = max(0, totalCharacters)
        self.completedCharacters = min(max(0, completedCharacters), self.totalCharacters)
    }
}

public typealias TranslationProgressHandler = @MainActor (TranslationProgress) -> Void

/// Count source characters only after a nonempty response for that segment arrives.
/// A duplicate or invalid batch identifier must never inflate the displayed count.
public struct TranslationProgressTracker: Sendable {
    private let lengths: [Int]
    private var completed: Set<Int> = []
    private var count = 0
    public init(texts: [String]) { lengths = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).count } }
    public var progress: TranslationProgress {
        TranslationProgress(completedCharacters: count, totalCharacters: lengths.reduce(0, +))
    }
    public mutating func complete(index: Int, translation: String) throws -> TranslationProgress {
        guard lengths.indices.contains(index), !completed.contains(index),
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationFailure.incompleteResponse
        }
        completed.insert(index)
        count += lengths[index]
        return progress
    }
}

public enum FeedbackPlacement {
    /// Cocoa coordinates. Prefer below the selection/caret, then above it; stay on screen.
    public static func frame(size: CGSize, anchor: CGRect, visible: CGRect, margin: CGFloat = 12) -> CGRect {
        let width = min(size.width, max(0, visible.width - margin * 2))
        let height = min(size.height, max(0, visible.height - margin * 2))
        let x = min(max(anchor.minX, visible.minX + margin), visible.maxX - width - margin)
        let below = anchor.minY - height - 10
        let above = anchor.maxY + 10
        let preferred = below >= visible.minY + margin ? below : above
        let y = min(max(preferred, visible.minY + margin), visible.maxY - height - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

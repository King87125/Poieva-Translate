import Foundation

public enum SelectionRestorationFailure: LocalizedError, Equatable {
    case focusChanged, selectionChanged, notRestored
    public var errorDescription: String? {
        switch self {
        case .focusChanged: return L10n.tr("输入位置已改变，未自动替换。")
        case .selectionChanged: return L10n.tr("光标或选区已改变，未自动替换。")
        case .notRestored: return L10n.tr("输入框尚未确认光标恢复，未自动替换。")
        }
    }
}

/// Wait for the editor to acknowledge our temporary selection restoration.
/// Never restore over a different selection made by the user in the meantime.
@MainActor
public enum SelectionRestorer {
    @discardableResult
    public static func restore(original: TextSelection?, temporary: TextSelection?,
        isFocused: () -> Bool, current: () -> TextSelection?, canSet: () -> Bool,
        set: (TextSelection) -> Bool,
        wait: @MainActor () async -> Void = {
            // Cleanup must still wait when the translation task has been cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { continuation.resume() }
            }
        }) async throws -> Bool {
        guard isFocused() else { throw SelectionRestorationFailure.focusChanged }
        guard let original else { return false }
        let before = current()
        if before == original { return true }
        guard let temporary, before == temporary else { throw SelectionRestorationFailure.selectionChanged }
        guard canSet() else { return false }
        guard set(original) else { throw SelectionRestorationFailure.notRestored }
        for _ in 0..<6 {
            guard isFocused() else { throw SelectionRestorationFailure.focusChanged }
            let actual = current()
            if actual == original { return true }
            guard actual == temporary else { throw SelectionRestorationFailure.selectionChanged }
            await wait()
        }
        guard isFocused() else { throw SelectionRestorationFailure.focusChanged }
        guard current() == original else { throw SelectionRestorationFailure.notRestored }
        return true
    }
}

import AppKit
import ApplicationServices
import Carbon
import TypeBridgeCore

enum TextAccessFailure: LocalizedError {
    case permission, noTarget, secureField, notEditable, noSelection, emptyInput, unreadable
    case unsafeSelection, editorUnavailable(String), changedTarget(String)

    var errorDescription: String? {
        switch self {
        case .permission: return L10n.tr("请先开启「辅助功能」权限，\(AppBrand.name) 才能读取选中文字和回填输入框。")
        case .noTarget: return L10n.tr("请先把光标放在其他应用的输入框中，再按快捷键。")
        case .secureField: return L10n.tr("密码输入框不参与翻译。")
        case .notEditable: return L10n.tr("当前位置不是可编辑输入框，请把光标放入输入框后重试。")
        case .noSelection: return L10n.tr("没有读到选中文字，请选中文字后再试。")
        case .emptyInput: return L10n.tr("输入框还是空的，先写下想翻译的内容。")
        case .unreadable: return L10n.tr("暂时无法读取这个输入框，可以把文字粘贴到翻译窗口。")
        case .unsafeSelection: return L10n.tr("当前编辑器无法确认局部输入范围，请先选中文字，再使用「选中文字翻译」。")
        case let .editorUnavailable(name): return L10n.tr("\(name) 暂未提供可读取的编辑控件。请点击具体输入位置后重试，或选中文字翻译。")
        case let .changedTarget(reason): return reason
        }
    }
}

enum TextReadStrategy { case accessibilityValue, clipboard }

@MainActor
/// Capture diagnostics contain no captured text and are never persisted.
enum ContextReadStatus {
    case available, empty, disabled, wholeInput, unavailable(String)

    var title: String {
        switch self {
        case .available: return L10n.tr("已读取前后文")
        case .empty: return L10n.tr("选区周围没有文字")
        case .disabled: return L10n.tr("上下文已关闭")
        case .wholeInput: return L10n.tr("全文翻译")
        case .unavailable: return L10n.tr("未读到前后文")
        }
    }
    var detail: String {
        switch self {
        case .available: return L10n.tr("只读取当前文字区域中选区前后的有限文字。")
        case .empty: return L10n.tr("当前文字区域没有可供参考的前后文。")
        case .disabled: return L10n.tr("可在翻译偏好中开启上下文。")
        case .wholeInput: return L10n.tr("整个输入框已作为原文，不额外读取其他区域。")
        case let .unavailable(reason): return reason
        }
    }
}

struct TextCapture {
    let element: AXUIElement
    let application: NSRunningApplication
    let text: String
    let originalState: WritebackState
    let readStrategy: TextReadStrategy
    let scope: EditorScope
    let inputScope: InputTranslationScope
    let format: CapturedTextFormat
    let feedbackAnchor: CGRect?
    let context: TranslationContext
    let contextStatus: ContextReadStatus
}

@MainActor
final class TextAccess {
    private let editor = AccessibilityTextEditor()
    private var pendingClipboardRestore: (snapshot: ClipboardSnapshot, count: Int, id: UUID)?
    private var clipboardTask: Task<Void, Never>?
    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPermissionSettings()
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    func capture(_ action: ShortcutAction, preserveCode: Bool = true, useContext: Bool = false) async throws -> TextCapture {
        guard isTrusted else { throw TextAccessFailure.permission }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw TextAccessFailure.noTarget }
        if let clipboardTask { await clipboardTask.value }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw TextAccessFailure.changedTarget(L10n.tr("输入位置已改变，请回到原输入框重新触发翻译。"))
        }
        let element = try await editor.prepare(in: app, action: action)
        guard !editor.isSecure(element) else { throw TextAccessFailure.secureField }
        let scope = editor.scope(element)
        let initialRange = editor.selectedRange(element)
        let initialSelection = editor.selectedText(element)
        let inputScope = InputTranslationPolicy.scope(selectedText: initialSelection, selectedRange: initialRange)
        var strategy = TextReadStrategy.accessibilityValue
        let text: String
        if action == .input {
            guard editor.isEditable(element) else { throw TextAccessFailure.notEditable }
            if inputScope == .selection {
                if let selected = initialSelection, !selected.isEmpty { text = selected }
                else {
                    text = try await copySelectedText(element, app: app)
                    strategy = .clipboard
                }
                guard InputTranslationPolicy.isConsistentSelection(text, range: initialRange) else {
                    throw TextAccessFailure.unsafeSelection
                }
            } else if scope == .documentContainer {
                throw TextAccessFailure.unsafeSelection
            } else if let value = editor.value(element), !value.isEmpty {
                text = value
            } else if editor.characterCount(element) == 0 {
                throw TextAccessFailure.emptyInput
            } else {
                text = try await readWholeEditor(element, app: app, scope: scope)
                strategy = .clipboard
            }
        } else if let selected = initialSelection, !selected.isEmpty {
            text = selected
        } else {
            text = try await copySelectedText(element, app: app)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw action == .input ? TextAccessFailure.emptyInput : TextAccessFailure.noSelection
        }
        let context: TranslationContext
        let contextStatus: ContextReadStatus
        if !useContext { context = .init(); contextStatus = .disabled }
        else if action == .input && inputScope != .selection { context = .init(); contextStatus = .wholeInput }
        else { (context, contextStatus) = captureContext(element, selection: initialRange, expected: text, scope: scope) }
        let format: CapturedTextFormat
        do {
            format = try await captureFormat(element, app: app, scope: scope,
                inputScope: action == .input ? inputScope : .selection, text: text, preserveCode: preserveCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as SelectionRestorationFailure { throw TextAccessFailure.changedTarget(error.localizedDescription) }
        catch { format = .unavailable }
        try requireFocus(element, app: app)
        if inputScope == .selection || (initialRange != nil && editor.canSetRange(element)), initialRange != editor.selectedRange(element) {
            throw TextAccessFailure.changedTarget(L10n.tr("选区已经改变，请重新选中文字后翻译。"))
        }
        let state = WritebackState(processID: app.processIdentifier, hasSameFocus: true,
            text: action == .input ? text : nil, selection: editor.selectedRange(element))
        let anchor = editor.feedbackBounds(element).map { rect in
            CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY,
                   width: rect.width, height: rect.height)
        }
        return TextCapture(element: element, application: app, text: text,
            originalState: state, readStrategy: strategy, scope: scope, inputScope: inputScope, format: format,
            feedbackAnchor: anchor, context: context, contextStatus: contextStatus)
    }

    /// Query the same text element only. Context collection never changes selection,
    /// sends Select All, or walks other windows/blocks to find more content.
    private func captureContext(_ element: AXUIElement, selection: TextSelection?, expected: String,
                                scope: EditorScope) -> (TranslationContext, ContextReadStatus) {
        guard let selection, selection.location >= 0, selection.length > 0, selection.length == expected.utf16.count,
              selection.location <= Int.max - selection.length,
              editor.selectedRange(element) == selection else {
            return (.init(), .unavailable(L10n.tr("当前应用没有提供可核实的选区位置；本次只翻译选中文字。")))
        }
        if editor.text(in: selection, on: element) == expected {
            let window = TranslationContext.maximumCharactersPerSide
            let beforeLength = min(window, selection.location)
            let before = beforeLength > 0 ? editor.text(in: TextSelection(location: selection.location - beforeLength, length: beforeLength), on: element) : ""
            let end = selection.location + selection.length
            var after: String?
            if let count = editor.characterCount(element), end <= count {
                let length = min(window, count - end)
                after = length > 0 ? editor.text(in: TextSelection(location: end, length: length), on: element) : ""
            }
            if (before?.isEmpty == false || after?.isEmpty == false || (before != nil && after != nil)),
               editor.selectedRange(element) == selection {
                let context = TranslationContext(before: before ?? "", after: after ?? "")
                return (context, context.isEmpty ? .empty : .available)
            }
        }
        guard scope != .documentContainer, let value = editor.value(element),
              editor.selectedRange(element) == selection,
              let context = TranslationContext.capture(in: value, selection: selection, expected: expected) else {
            return (.init(), .unavailable(L10n.tr("当前应用未开放选区周围的文字，或选区位置已改变；本次只翻译选中文字。")))
        }
        return (context, context.isEmpty ? .empty : .available)
    }

    func replaceInput(_ capture: TextCapture, with content: TranslatedContent, onCommit: () -> Void) async throws {
        try Task.checkCancellation()
        if let refusal = content.writebackRefusal { throw TextAccessFailure.changedTarget(refusal) }
        let text = content.text
        try requireFocus(capture.element, app: capture.application)
        guard !editor.isSecure(capture.element) else { throw TextAccessFailure.secureField }
        if capture.inputScope == .selection {
            try await replaceSelection(capture, with: content, onCommit: onCommit)
            return
        }
        guard editor.isEditable(capture.element), editor.scope(capture.element) != .documentContainer else {
            throw TextAccessFailure.unsafeSelection
        }
        let currentText = try await currentFullText(capture)
        let current = WritebackState(processID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            hasSameFocus: editor.isFocused(capture.element, in: capture.application),
            text: currentText, selection: editor.selectedRange(capture.element))
        if let refusal = WritebackPolicy.refusal(original: capture.originalState, current: current) {
            throw TextAccessFailure.changedTarget(refusal)
        }
        let localRangeWasSet = try await selectWholeEditor(capture.element, app: capture.application, scope: capture.scope,
            expectedText: capture.text, currentLength: capture.text.utf16.count)
        // Re-read the source after selection. Never paste into an unverifiable or changed editor.
        let verified = try await currentFullText(capture)
        guard verified == capture.text else {
            throw TextAccessFailure.changedTarget(L10n.tr("原文已经改变，译文已保留，没有覆盖新内容。"))
        }
        try Task.checkCancellation()
        try requireFocus(capture.element, app: capture.application)
        guard EditorSelectionPolicy.verifies(scope: capture.scope, expectedText: capture.text,
            expectedUTF16Length: capture.text.utf16.count, selectedText: editor.selectedText(capture.element),
            selectedRange: editor.selectedRange(capture.element), localRangeWasSet: localRangeWasSet) else {
            throw TextAccessFailure.unsafeSelection
        }
        try await paste(content, onCommit: onCommit)
        try requirePastedFocus(capture)
        let actual: String
        if capture.readStrategy == .accessibilityValue, let value = editor.value(capture.element) {
            actual = value
        } else {
            actual = try await readWholeEditor(capture.element, app: capture.application, scope: capture.scope)
        }
        guard actual == text else { throw unconfirmedWriteback }
    }

    private var unconfirmedWriteback: TextAccessFailure {
        .changedTarget(L10n.tr("回填结果尚未确认，译文已保留，请核对后手动复制。"))
    }

    private func replaceSelection(_ capture: TextCapture, with content: TranslatedContent, onCommit: () -> Void) async throws {
        guard editor.isEditable(capture.element) else { throw TextAccessFailure.notEditable }
        let text = content.text
        // This path never sends Select All or changes the user's selected range.
        let range = capture.originalState.selection
        let currentText = try await currentSelectedText(capture)
        let currentRange = editor.selectedRange(capture.element)
        let current = WritebackState(processID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            hasSameFocus: editor.isFocused(capture.element, in: capture.application),
            text: currentText, selection: currentRange)
        let full = editor.scope(capture.element) == .documentContainer ? nil : editor.value(capture.element)
        let expectedFullText: String?
        switch InputTranslationPolicy.selectionWritebackPlan(original: capture.originalState,
            current: current, editorText: full, translation: text) {
        case let .refuse(reason): throw TextAccessFailure.changedTarget(reason)
        case let .replace(expected): expectedFullText = expected
        }
        try Task.checkCancellation()
        try requireFocus(capture.element, app: capture.application)
        guard editor.selectedRange(capture.element) == currentRange else {
            throw TextAccessFailure.changedTarget(L10n.tr("选区已经改变，译文已保留，没有自动回填。"))
        }
        if let selected = editor.selectedText(capture.element), !selected.isEmpty, selected != capture.text {
            throw TextAccessFailure.changedTarget(L10n.tr("选中的原文已经改变，译文已保留，没有自动回填。"))
        }
        try await paste(content, onCommit: onCommit)
        try requirePastedFocus(capture)
        if let expectedFullText, let actual = editor.value(capture.element) {
            guard actual == expectedFullText else { throw unconfirmedWriteback }
            return
        }
        if let range, editor.scope(capture.element) != .documentContainer {
            let pastedRange = TextSelection(location: range.location, length: text.utf16.count)
            if editor.text(in: pastedRange, on: capture.element) == text { return }
        }
        if editor.selectedText(capture.element) == text { return }
        throw unconfirmedWriteback
    }

    private func currentSelectedText(_ capture: TextCapture) async throws -> String {
        let range = editor.selectedRange(capture.element)
        let selected = editor.selectedText(capture.element)
        guard InputTranslationPolicy.scope(selectedText: selected, selectedRange: range) == .selection else {
            throw TextAccessFailure.changedTarget(L10n.tr("选区已经取消，译文已保留，没有自动回填。"))
        }
        let text: String
        if let selected, !selected.isEmpty { text = selected }
        else { text = try await copySelectedText(capture.element, app: capture.application) }
        guard InputTranslationPolicy.isConsistentSelection(text, range: range) else {
            throw TextAccessFailure.unsafeSelection
        }
        return text
    }

    private func requirePastedFocus(_ capture: TextCapture) throws {
        try Task.checkCancellation()
        guard editor.isFocused(capture.element, in: capture.application) else {
            throw TextAccessFailure.changedTarget(L10n.tr("已发出回填，但输入位置已改变，无法确认结果；请核对原输入框，译文也已保留。"))
        }
    }

    private func paste(_ content: TranslatedContent, onCommit: () -> Void) async throws {
        let snapshot = ClipboardSnapshot()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([content.pasteboardItem()]) else {
            snapshot.restore(ifOwned: pasteboard.changeCount)
            throw TextAccessFailure.unreadable
        }
        let id = UUID()
        pendingClipboardRestore = (snapshot, pasteboard.changeCount, id)
        onCommit()
        sendKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, let pending = self.pendingClipboardRestore, pending.id == id else { return }
            pending.snapshot.restore(ifOwned: pending.count)
            self.pendingClipboardRestore = nil
            self.clipboardTask = nil
        }
        clipboardTask = task
        await task.value
    }

    func restoreClipboard() {
        clipboardTask?.cancel()
        clipboardTask = nil
        if let pending = pendingClipboardRestore { pending.snapshot.restore(ifOwned: pending.count) }
        pendingClipboardRestore = nil
    }

    private func currentFullText(_ capture: TextCapture) async throws -> String {
        if capture.readStrategy == .accessibilityValue, let value = editor.value(capture.element) { return value }
        return try await readWholeEditor(capture.element, app: capture.application, scope: capture.scope)
    }

    private func readWholeEditor(_ element: AXUIElement, app: NSRunningApplication, scope: EditorScope) async throws -> String {
        try requireFocus(element, app: app)
        if let value = editor.value(element), !value.isEmpty { return value }
        let length = editor.characterCount(element)
        if let length, length > 0,
           let text = editor.text(in: TextSelection(location: 0, length: length), on: element), text.utf16.count == length {
            return text
        }
        let range = editor.selectedRange(element)
        guard length != 0 else { throw TextAccessFailure.emptyInput }
        _ = try await selectWholeEditor(element, app: app, scope: scope, expectedText: nil, currentLength: length)
        let temporary = editor.selectedRange(element)
        do {
            let result: String
            if let selected = editor.selectedText(element), !selected.isEmpty { result = selected }
            else { result = try await copySelectedText(element, app: app) }
            if let length, result.utf16.count != length { throw TextAccessFailure.unsafeSelection }
            try await restoreRange(range, temporary: temporary, on: element, app: app)
            return result
        } catch let error as SelectionRestorationFailure { throw error }
        catch {
            try? await restoreRange(range, temporary: temporary, on: element, app: app)
            throw error
        }
    }

    private func selectWholeEditor(_ element: AXUIElement, app: NSRunningApplication, scope: EditorScope,
                                   expectedText: String?, currentLength: Int?) async throws -> Bool {
        try requireFocus(element, app: app)
        let selected = editor.selectedText(element)
        let matches = expectedText.map { selected == $0 } ?? currentLength.map { selected?.utf16.count == $0 } ?? false
        let plan = EditorSelectionPolicy.plan(scope: scope, textUTF16Length: currentLength,
            currentRange: editor.selectedRange(element), selectionMatchesText: matches,
            canSetLocalRange: editor.canSetRange(element), canReadSelectedText: selected != nil)
        var localRangeWasSet = false
        switch plan {
        case .reuseSelection: break
        case let .setLocalRange(range):
            guard editor.setRange(range, on: element) else { throw TextAccessFailure.unsafeSelection }
            localRangeWasSet = true
        case .keyboardSelectAllOnce: sendKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        case .requireUserSelection: throw TextAccessFailure.unsafeSelection
        }
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(40))
            try requireFocus(element, app: app)
            if EditorSelectionPolicy.verifies(scope: scope, expectedText: expectedText,
                expectedUTF16Length: currentLength, selectedText: editor.selectedText(element),
                selectedRange: editor.selectedRange(element), localRangeWasSet: localRangeWasSet) { return localRangeWasSet }
        }
        throw TextAccessFailure.unsafeSelection
    }

    private func copySelectedText(_ element: AXUIElement, app: NSRunningApplication) async throws -> String {
        (try await copySelection(element, app: app)).text
    }

    private struct CopiedSelection {
        let text: String
        let html: Data?
        let rtf: Data?
        let declaresRichText: Bool
    }

    private func captureFormat(_ element: AXUIElement, app: NSRunningApplication, scope: EditorScope,
                               inputScope: InputTranslationScope, text: String, preserveCode: Bool) async throws -> CapturedTextFormat {
        let range = editor.selectedRange(element)
        if inputScope == .wholeInput {
            _ = try await selectWholeEditor(element, app: app, scope: scope,
                expectedText: text, currentLength: text.utf16.count)
        }
        let temporary = editor.selectedRange(element)
        do {
            let copied = try await copySelection(element, app: app)
            guard copied.text == text else { throw FormattingFailure.cannotPreserve }
            let result = CapturedTextFormat.capture(html: copied.html, rtf: copied.rtf, declaresRichText: copied.declaresRichText,
                text: text, preserveCode: preserveCode, scope: scope)
            if inputScope == .wholeInput { try await restoreRange(range, temporary: temporary, on: element, app: app) }
            return result
        } catch let error as SelectionRestorationFailure { throw error }
        catch {
            if inputScope == .wholeInput { try? await restoreRange(range, temporary: temporary, on: element, app: app) }
            throw error
        }
    }

    private func restoreRange(_ original: TextSelection?, temporary: TextSelection?, on element: AXUIElement,
                              app: NSRunningApplication) async throws {
        try await SelectionRestorer.restore(original: original, temporary: temporary,
            isFocused: { self.editor.isFocused(element, in: app) }, current: { self.editor.selectedRange(element) },
            canSet: { self.editor.canSetRange(element) }, set: { self.editor.setRange($0, on: element) })
    }

    private func copySelection(_ element: AXUIElement, app: NSRunningApplication) async throws -> CopiedSelection {
        try requireFocus(element, app: app)
        guard !editor.isSecure(element) else { throw TextAccessFailure.secureField }
        let snapshot = ClipboardSnapshot()
        let pasteboard = NSPasteboard.general
        let startingCount = pasteboard.changeCount
        var copiedCount: Int?
        defer { if let copiedCount { snapshot.restore(ifOwned: copiedCount) } }
        sendKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        for _ in 0..<20 {
            // Complete restoration even if cancellation arrives after the Copy event.
            try? await Task.sleep(for: .milliseconds(30))
            if pasteboard.changeCount != startingCount {
                copiedCount = pasteboard.changeCount
                try requireFocus(element, app: app)
                guard let text = pasteboard.string(forType: .string) else { throw TextAccessFailure.unreadable }
                let richTypes: Set<NSPasteboard.PasteboardType> = [.html, .rtf, .rtfd]
                return CopiedSelection(text: text, html: pasteboard.data(forType: .html), rtf: pasteboard.data(forType: .rtf),
                    declaresRichText: !(richTypes.intersection(Set(pasteboard.types ?? []))).isEmpty)
            }
        }
        throw TextAccessFailure.noSelection
    }

    private func requireFocus(_ element: AXUIElement, app: NSRunningApplication) throws {
        guard editor.isFocused(element, in: app) else {
            throw TextAccessFailure.changedTarget(L10n.tr("输入位置已改变，请回到原输入框重新触发翻译。"))
        }
    }

    private func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

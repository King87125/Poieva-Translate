import AppKit

/// Own the placeholder and composition state in the native editor so uncommitted
/// marked text never races a SwiftUI overlay or a stale bound string.
@MainActor
public final class WorkbenchTextView: NSTextView {
    public var onEditingChange: ((String, Bool) -> Void)?
    private var applyingModelText = false

    public var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsPlaceholder {
            let text = NSAttributedString(string: L10n.tr("输入或粘贴文字"), attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.placeholderTextColor
            ])
            text.draw(at: textContainerOrigin)
        }
    }

    public func applyModelText(_ text: String, replacingComposition: Bool = false) {
        guard replacingComposition || !hasMarkedText() else { return }
        guard string != text || replacingComposition else { return }
        applyingModelText = true
        if replacingComposition, hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        string = text
        needsDisplay = true
        applyingModelText = false
    }

    public override func didChangeText() {
        super.didChangeText()
        notifyEditingChange()
    }

    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        notifyEditingChange()
    }

    public override func unmarkText() {
        super.unmarkText()
        notifyEditingChange()
    }

    public override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        notifyEditingChange()
    }

    private func notifyEditingChange() {
        needsDisplay = true
        if !applyingModelText { onEditingChange?(string, hasMarkedText()) }
    }
}

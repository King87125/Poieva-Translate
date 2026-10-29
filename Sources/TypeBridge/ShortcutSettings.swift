import TypeBridgeCore
import AppKit
import SwiftUI

@MainActor
struct ShortcutSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var editingAction: ShortcutAction?

    var body: some View {
        Group {
            shortcutRow(.input, shortcut: settings.inputShortcut)
                .sheet(item: $editingAction) { action in ShortcutEditorSheet(model: model, action: action) }
            shortcutRow(.selection, shortcut: settings.selectionShortcut)
            HStack {
                Spacer()
                Button(L10n.tr("恢复默认快捷键")) { model.restoreDefaultShortcuts() }.disabled(model.busy || model.preparing)
            }
            if !model.shortcutMessage.isEmpty { Text(model.shortcutMessage).foregroundStyle(.red) }
        }
    }

    private func shortcutRow(_ action: ShortcutAction, shortcut: KeyboardShortcut) -> some View {
        HStack(spacing: 12) {
            Text(action.title)
            Spacer()
            Text(shortcut.readableLabel).monospaced().foregroundStyle(.secondary)
                .accessibilityLabel(L10n.tr("\(action.title)当前快捷键：\(shortcut.readableLabel)"))
            Button(L10n.tr("修改…")) { editingAction = action }
                .accessibilityLabel(L10n.tr("修改\(action.title)快捷键")).disabled(model.busy || model.preparing)
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct ShortcutEditorSheet: View {
    @ObservedObject var model: AppModel
    let action: ShortcutAction
    @Environment(\.dismiss) private var dismiss
    @State private var monitor: Any?
    @State private var preview = L10n.tr("按下快捷键")
    @State private var errorMessage = ""
    @State private var completed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("设置快捷键")).font(.headline)
            Text(action.title).foregroundStyle(.secondary)
            GroupBox {
                Text(preview).font(.title3.monospaced())
                    .frame(maxWidth: .infinity, minHeight: 48).accessibilityLabel(L10n.tr("快捷键录入：\(preview)"))
            }
            Text(L10n.tr("按组合键后自动保存。Esc 取消。")).font(.callout).foregroundStyle(.secondary)
            if !errorMessage.isEmpty { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 380)
        .onAppear(perform: startRecording)
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in dismiss() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        model.beginShortcutEditing()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard !completed else { return nil }
            if event.type == .flagsChanged {
                if errorMessage.isEmpty { preview = KeyboardShortcut.modifierPreview(event) }
                return event
            }
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                dismiss()
                return nil
            }
            guard let shortcut = KeyboardShortcut(event: event) else {
                errorMessage = L10n.tr("请搭配 Command、Option 或 Control；也可使用 F1–F20。")
                return nil
            }
            preview = shortcut.readableLabel
            if let failure = model.saveShortcut(shortcut, for: action) { errorMessage = failure }
            else { completed = true; dismiss() }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.endShortcutEditing()
    }
}

import SwiftUI
import TypeBridgeCore

@MainActor
struct TranslationPreferenceSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationPreferenceStore
    @ObservedObject var services: TranslationServiceStore
    @State private var error = ""

    private var assistantOptions: [SelectionOption<String>] {
        [SelectionOption("off", L10n.tr("关闭"))] +
        services.configurations.filter(\.isRemoteModelAPI).map { SelectionOption($0.id.uuidString, $0.name) } +
        (missingAssistant ? [SelectionOption(store.settings.assistant, L10n.tr("请选择远程 API"))] : [])
    }
    private var missingAssistant: Bool {
        store.settings.assistant != "off" &&
        !services.configurations.contains { $0.id.uuidString == store.settings.assistant && $0.isRemoteModelAPI }
    }
    private var assistantService: TranslationServiceConfiguration? {
        services.configurations.first { $0.id.uuidString == store.settings.assistant }
    }

    var body: some View {
        Toggle(L10n.tr("参考前后文"), isOn: Binding(get: { store.settings.useContext }, set: { value in
            update { $0.useContext = value }
        })).toggleStyle(.switch).controlSize(.small).disabled(model.committing)
        HStack {
            Text(L10n.tr("辅助模型 API"))
            Spacer()
            SelectionField(title: L10n.tr("辅助模型 API"), selection: Binding(get: { store.settings.assistant }, set: { value in
                update { $0.assistant = value }
            }), options: assistantOptions).frame(width: 170)
            Button(L10n.tr("管理…")) { model.showServices() }.accessibilityLabel(L10n.tr("打开模型管理配置辅助 API"))
        }.disabled(model.committing)
        if missingAssistant {
            Text(L10n.tr("请选择已配置的远程 AI API。")).font(.caption).foregroundStyle(.orange)
        } else if let service = assistantService {
            Text(L10n.tr("待译文字、附近上下文和相关偏好会发送给「\(service.name)」。"))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(L10n.tr("AI 翻译服务直接使用上下文与偏好；苹果及专业翻译需选择辅助模型。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Text(L10n.tr("术语库、语气与场景"))
            Spacer()
            Button(L10n.tr("管理方案…")) { model.showProfiles() }.disabled(model.committing)
        }
        if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        if !store.issue.isEmpty { Text(store.issue).font(.caption).foregroundStyle(.red) }
    }
    private func update(_ change: (inout TranslationAssistanceSettings) -> Void) {
        var settings = store.settings; change(&settings)
        do { try store.save(settings); error = "" } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct WorkbenchContextEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var before: String
    @State private var after: String
    init(model: AppModel) {
        self.model = model
        _before = State(initialValue: model.contextBefore); _after = State(initialValue: model.contextAfter)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L10n.tr("翻译上下文")).font(.headline); Spacer() }.padding(20)
            Divider()
            Form {
                Section(L10n.tr("前文")) { TextEditor(text: $before).frame(height: 100).accessibilityLabel(L10n.tr("前文内容")) }
                Section(L10n.tr("后文")) { TextEditor(text: $after).frame(height: 100).accessibilityLabel(L10n.tr("后文内容")) }
                Text(L10n.tr("仅供参考，不会翻译或回填。前文保留末尾 600 字，后文保留开头 600 字。"))
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = model.workbenchAssistanceIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button(L10n.tr("清空")) { before = ""; after = "" }
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("使用")) { model.updateWorkbenchContext(before: before, after: after); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(model.translatingOutsideWorkbench)
            }.padding(16)
        }.frame(width: 520, height: 440)
    }
}

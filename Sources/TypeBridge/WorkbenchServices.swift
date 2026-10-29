import SwiftUI
import TypeBridgeCore

@MainActor
struct WorkbenchServiceChooser: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationServiceStore
    private var title: String {
        if !model.hasWorkbenchServices { return L10n.tr("选择服务") }
        if model.isComparing { return L10n.tr("已选 \(model.workbenchServiceIDs.count) 个服务") }
        return store.activeName
    }
    var body: some View {
        Menu {
            Section(L10n.tr("翻译服务")) {
                ForEach(model.workbenchServiceChoices) { service in
                    Toggle(service.name, isOn: Binding(get: {
                        model.workbenchServiceIDs.contains(service.id)
                    }, set: { selected in
                        var ids = Set(model.workbenchServiceIDs)
                        if selected { ids.insert(service.id) } else { ids.remove(service.id) }
                        model.useWorkbenchServices(model.workbenchServiceChoices.filter { ids.contains($0.id) }.map(\.id))
                    }))
                }
            }
            Divider()
            Button(L10n.tr("模型管理…")) { model.showServices() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: model.isComparing ? "rectangle.on.rectangle" : "arrow.left.arrow.right").foregroundStyle(.secondary)
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }.menuStyle(.button).menuIndicator(.hidden).buttonStyle(SelectionFieldStyle())
        .accessibilityLabel(L10n.tr("翻译服务")).accessibilityValue(title)
    }
}

@MainActor
struct ComparisonResultsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: WorkbenchComparisonController
    @ObservedObject var settings: AppSettings
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(controller.results) { result in
                    ComparisonResultRow(model: model, settings: settings, result: result)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel(L10n.tr("各服务译文"))
    }
}

@MainActor
private struct ComparisonResultRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let result: WorkbenchServiceResult
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(result.service.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 4)
                if result.phase == .translating {
                    InlineFeedbackView(state: TranslationFeedback(id: UUID(), phase: .translating, surface: .workbench,
                        title: L10n.tr("正在翻译"), progress: result.progress), style: settings.feedbackStyle, animates: model.workbenchVisible)
                } else {
                    Button { model.retryComparison(result.id) } label: { Image(systemName: "arrow.clockwise") }
                        .help(L10n.tr("重新翻译")).accessibilityLabel(L10n.tr("重新翻译 \(result.service.name)"))
                        .disabled(model.isComposing || model.preparing || model.translatingOutsideWorkbench || model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { model.copy(result.text) } label: { Image(systemName: "doc.on.doc") }
                        .help(L10n.tr("复制译文")).accessibilityLabel(L10n.tr("复制 \(result.service.name) 译文")).disabled(result.text.isEmpty)
                }
            }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
            if !result.error.isEmpty {
                Label { Text(result.error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if !result.text.isEmpty {
                Text(result.text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else { Color.clear.frame(height: 26) }
        }.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
    }
}

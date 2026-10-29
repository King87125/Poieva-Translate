import SwiftUI
import UniformTypeIdentifiers
import TypeBridgeCore

@MainActor
struct SampleProfileGenerationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationProfileStore
    @ObservedObject var services: TranslationServiceStore
    @Environment(\.dismiss) private var dismiss
    @State private var input: ProfileGenerationInput
    @State private var serviceID: UUID?
    @State private var draft: GeneratedTranslationProfile?
    @State private var reviewing = false
    @State private var generating = false
    @State private var importing = false
    @State private var filename = ""
    @State private var error = ""
    @State private var task: Task<Void, Never>?
    @State private var generator: SampleProfileGenerator?
    @State private var requestID = UUID()
    let onSaved: (UUID) -> Void

    init(model: AppModel, store: TranslationProfileStore, onSaved: @escaping (UUID) -> Void) {
        self.model = model; self.store = store; services = model.services; self.onSaved = onSaved
        var value = ProfileGenerationInput(); value.interfaceLanguage = L10n.language
        _input = State(initialValue: value)
        let ai = model.services.configurations.filter { $0.adapter == .openAICompatible }
        let selected = ai.first { $0.id.uuidString == model.translationPreferences.settings.assistant } ?? ai.first
        _serviceID = State(initialValue: selected?.id)
    }
    private var aiServices: [TranslationServiceConfiguration] { services.configurations.filter { $0.adapter == .openAICompatible } }
    private var configuration: TranslationServiceConfiguration? { aiServices.first { $0.id == serviceID } }
    private var draftBinding: Binding<GeneratedTranslationProfile> {
        Binding(get: { draft ?? .init() }, set: { if draft != nil { draft = $0 } })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reviewing ? L10n.tr("修改生成的方案") : L10n.tr("从样例生成")).font(.title3.weight(.semibold))
                    Text(reviewing ? L10n.tr("确认术语和规则后，再保存使用") : L10n.tr("粘贴对话、邮件，或添加自己的文本"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if reviewing { Text(L10n.tr("方案草稿")).font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
            Divider()
            ScrollView {
                if reviewing, draft != nil {
                    GeneratedProfileReview(draft: draftBinding).padding(20)
                } else { inputForm.padding(20) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if reviewing, model.workbenchAssistanceIssue != nil {
                    Text(L10n.tr("当前翻译服务需要 AI 辅助才能应用方案。")).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if reviewing { Button(L10n.tr("修改样例")) { reviewing = false; error = "" } }
                    Button(L10n.tr("关闭草稿")) { close() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if reviewing {
                        Button(L10n.tr("只保存")) { save(activate: false) }.disabled(model.committing)
                        Button(L10n.tr("保存并使用")) { save(activate: true) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.committing)
                    } else if generating {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在整理术语和表达习惯…")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.tr("取消生成")) { cancelGeneration() }
                    } else {
                        if draft != nil { Button(L10n.tr("返回草稿")) { reviewing = true } }
                        Button(L10n.tr("生成草稿")) { generate() }.buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(configuration == nil || input.sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding(16)
        }.frame(width: 800, height: 720)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            do {
                let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= ProfileSampleTextFile.maximumBytes else { throw ProfileGenerationFailure.fileTooLarge }
                let text = try ProfileSampleTextFile.decode(Data(contentsOf: url))
                let combined = input.sample.isEmpty ? text : input.sample + "\n\n" + text
                guard combined.count <= ProfileGenerationInput.maximumCharacters else { throw ProfileGenerationFailure.tooLong }
                input.sample = combined; filename = url.lastPathComponent; error = ""
            } catch let issue as CocoaError where issue.code == .userCancelled {
                // Cancelling a file picker leaves the current sample untouched.
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: input) { _, _ in invalidateDraft() }
        .onChange(of: configuration) { _, _ in invalidateDraft() }
        .onChange(of: aiServices) { _, values in
            if !values.contains(where: { $0.id == serviceID }) { serviceID = values.first?.id }
        }
        .onDisappear { cancelGeneration(); input.sample = ""; input.identity = ""; input.purpose = ""; draft = nil; filename = "" }
    }
    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConfigurationGroup {
                HStack(alignment: .bottom, spacing: 12) {
                    ConfigurationField(title: L10n.tr("生成所用 AI")) {
                        SelectionField(title: L10n.tr("生成所用 AI"), selection: $serviceID,
                            options: aiServices.map { SelectionOption(Optional($0.id), $0.name) })
                    }
                    Button(L10n.tr("配置 AI…")) { model.showServices() }
                }
                if let configuration {
                    Text(L10n.tr("样例会发送至「\(configuration.name)」；原始样例不写入本机方案。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(URL(string: configuration.baseURL)?.host ?? "").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text(L10n.tr("请先在模型管理中添加自己的自定义 AI 服务。")).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(generating)
            HStack {
                Picker(L10n.tr("样例类型"), selection: $input.kind) {
                    ForEach(ProfileSampleKind.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 330).accessibilityLabel(L10n.tr("样例类型"))
                Spacer()
                Button(L10n.tr("添加文本文件…"), systemImage: "doc.badge.plus") { importing = true }
            }.disabled(generating)
            if input.kind != .writing {
                HStack {
                    Text(L10n.tr("我的发言标记")).font(.callout)
                    TextField(L10n.tr("例如：我、Alex，或发件人邮箱"), text: $input.identity).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("我的发言标记"))
                }.disabled(generating)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.tr("样例内容")).font(.callout.weight(.medium))
                    Spacer()
                    Text(L10n.tr("\(input.sample.count) / 20,000 字")).font(.caption).monospacedDigit()
                        .foregroundStyle(input.sample.count > ProfileGenerationInput.maximumCharacters ? Color.red : Color.secondary)
                }
                TextEditor(text: $input.sample).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(height: 210).padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5) }
                    .accessibilityLabel(L10n.tr("对话或邮件样例")).disabled(generating)
                HStack {
                    Text(filename.isEmpty ? L10n.tr("仅我的文字表示这些内容均由我撰写。") : L10n.tr("已添加：\(filename)"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(L10n.tr("清空")) { input.sample = ""; filename = "" }.disabled(generating || input.sample.isEmpty)
                }
            }
            ConfigurationField(title: L10n.tr("用于什么场景（可选）")) {
                TextField(L10n.tr("例如：和客户沟通项目进展，礼貌、简洁"), text: $input.purpose).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.tr("生成方案的场景要求"))
            }.disabled(generating)
            HStack {
                Text(L10n.tr("适用译文"))
                SelectionField(title: L10n.tr("生成方案适用语言"), selection: $input.target, options: generationLanguages).frame(width: 200)
                Spacer()
            }.disabled(generating)
        }
    }
    private func cancelGeneration() { requestID = UUID(); task?.cancel(); task = nil; generator?.cancel(); generator = nil; generating = false }
    private func invalidateDraft() { cancelGeneration(); draft = nil; reviewing = false; error = "" }
    private func close() { cancelGeneration(); dismiss() }
    private func generate() {
        do {
            let value = try input.validated()
            guard let configuration else { throw ProfileGenerationFailure.unsupportedService }
            cancelGeneration(); draft = nil; error = ""
            let provider = try SampleProfileGenerator(configuration: configuration, credential: { [weak services] in
                guard let services else { throw ServiceConfigurationFailure.credential }
                return try services.key(for: configuration.id)
            })
            let id = UUID(); requestID = id; generator = provider; generating = true
            task = Task { @MainActor in
                do {
                    let result = try await provider.generate(value)
                    guard !Task.isCancelled, requestID == id else { return }
                    draft = result; reviewing = true
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    self.error = error.localizedDescription
                }
                if requestID == id { generating = false; generator = nil; task = nil }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save(activate: Bool) {
        do {
            guard let draft else { throw ProfileGenerationFailure.invalidResponse }
            let id = try store.create(draft, activate: activate)
            onSaved(id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private var generationLanguages: [SelectionOption<AppLanguage>] {
    [SelectionOption(.automatic, L10n.tr("所有语言"))] + AppLanguage.targets.map { SelectionOption($0, $0.name) }
}

private struct GeneratedProfileReview: View {
    @Binding var draft: GeneratedTranslationProfile
    @State private var showingEvidence = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConfigurationGroup {
                HStack(alignment: .bottom, spacing: 16) {
                    ConfigurationField(title: L10n.tr("场景名称")) {
                        TextField(L10n.tr("场景名称"), text: $draft.name).textFieldStyle(.roundedBorder)
                    }
                    ConfigurationField(title: L10n.tr("适用译文")) {
                        SelectionField(title: L10n.tr("方案适用语言"), selection: $draft.target, options: generationLanguages)
                    }.frame(width: 190)
                }
            }
            ConfigurationGroup {
                HStack {
                    Text(L10n.tr("语气与表达规则")).font(.callout.weight(.medium))
                    Spacer()
                    SelectionField(title: L10n.tr("表达风格"), selection: $draft.tone,
                        options: TranslationTone.allCases.map { SelectionOption($0, $0.name) }).frame(width: 180)
                }
                SampleRulesEditor(text: $draft.toneInstructions, title: L10n.tr("生成的表达规则"), height: 58)
                Button(L10n.tr("查看表达依据"), systemImage: "quote.bubble") { showingEvidence = true }
                    .popover(isPresented: $showingEvidence) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.tr("来自样例的表达依据")).font(.headline)
                            ForEach(Array(draft.toneEvidence.enumerated()), id: \.offset) { _, quote in Text(quote).textSelection(.enabled) }
                            Text(L10n.tr("依据仅供本次查看，不写入保存的方案。")).font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(width: 430)
                    }.disabled(draft.toneEvidence.isEmpty)
            }
            ConfigurationGroup {
                ConfigurationField(title: L10n.tr("场景要求")) {
                    SampleRulesEditor(text: $draft.sceneInstructions, title: L10n.tr("生成的场景要求"), height: 50)
                }
            }
            HStack {
                Text(L10n.tr("术语建议")).font(.callout.weight(.medium))
                Text(L10n.tr("已采用 \(draft.terms.filter(\.included).count) / \(draft.terms.count) 条")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("添加术语"), systemImage: "plus") { draft.terms.append(.init()) }
            }
            if draft.terms.contains(where: { $0.basis == .suggested }) {
                Text(L10n.tr("推测译法默认不采用，确认后勾选即可。")).font(.caption).foregroundStyle(.secondary)
            }
            if draft.terms.isEmpty { Text(L10n.tr("没有提取到固定术语，可以自行添加。")).font(.callout).foregroundStyle(.secondary) }
            ForEach($draft.terms) { $candidate in
                GeneratedTermRow(candidate: $candidate) { draft.terms.removeAll { $0.id == candidate.id } }
            }
        }
    }
}

private struct SampleRulesEditor: View {
    @Binding var text: String
    let title: String
    let height: CGFloat
    var body: some View {
        TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden)
            .frame(height: height).padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5) }
            .accessibilityLabel(title)
    }
}

private struct GeneratedTermRow: View {
    @Binding var candidate: GeneratedTermCandidate
    let remove: () -> Void
    @State private var showingEvidence = false
    private var basis: String {
        if candidate.edited || candidate.basis == .manual { return L10n.tr("自行配置") }
        return candidate.basis == .observed ? L10n.tr("样例已有") : L10n.tr("AI 推测")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle(L10n.tr("采用"), isOn: $candidate.included).labelsHidden().accessibilityLabel(L10n.tr("采用术语 \(candidate.entry.source)"))
                TextField(L10n.tr("原文"), text: $candidate.entry.source).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.tr("建议术语原文"))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField(L10n.tr("固定译法"), text: $candidate.entry.translation).textFieldStyle(.roundedBorder)
                    .disabled(candidate.entry.preserveOriginal).accessibilityLabel(L10n.tr("建议术语译法"))
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel(L10n.tr("删除术语建议"))
            }
            HStack(spacing: 10) {
                SelectionField(title: L10n.tr("术语原文语言"), selection: $candidate.entry.sourceLanguage, options: generationLanguages).frame(width: 130)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                SelectionField(title: L10n.tr("术语目标语言"), selection: $candidate.entry.targetLanguage, options: generationLanguages).frame(width: 130)
                Toggle(L10n.tr("保留原文"), isOn: $candidate.entry.preserveOriginal).controlSize(.small)
                Spacer()
                Text(basis).font(.caption).foregroundStyle(candidate.basis == .suggested && !candidate.edited ? Color.orange : Color.secondary)
                if !candidate.evidence.isEmpty {
                    Button { showingEvidence = true } label: { Image(systemName: "quote.bubble") }
                        .accessibilityLabel(L10n.tr("查看术语依据"))
                        .popover(isPresented: $showingEvidence) { Text(candidate.evidence).textSelection(.enabled).padding(20).frame(width: 400) }
                }
            }.font(.caption)
        }.padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
    }
}

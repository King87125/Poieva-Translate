import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TypeBridgeCore

@MainActor
struct ServiceSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationServiceStore
    @State private var error = ""
    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("默认翻译"))
            Spacer()
            SelectionField(title: L10n.tr("默认翻译服务"), selection: Binding<UUID?>(get: { store.selectedID }, set: { value in
                do { try store.select(value); error = "" } catch { self.error = error.localizedDescription }
            }), options: [SelectionOption<UUID?>(nil, L10n.tr("苹果系统翻译"))] + store.configurations.map { SelectionOption(Optional($0.id), $0.name) })
                .frame(width: 180).disabled(model.committing)
            Button(L10n.tr("管理…")) { model.showServices() }.accessibilityLabel(L10n.tr("打开模型管理"))
        }.accessibilityElement(children: .contain)
        if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
        if !store.issue.isEmpty { Text(store.issue).font(.callout).foregroundStyle(.red) }
    }
}

@MainActor
struct ServiceManagementView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationServiceStore
    @State private var selection: String? = "apple"
    @State private var editing: TranslationServiceConfiguration?
    @State private var confirmingDelete = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: ServicePackageDocument?
    @State private var message = ""
    @State private var isError = false

    private var selected: TranslationServiceConfiguration? { store.configurations.first { $0.id.uuidString == selection } }
    private var isCurrent: Bool { selected?.id == store.selectedID }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.tr("默认翻译：\(store.activeName)")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("设为默认翻译")) {
                    perform { try store.select(selected?.id) }
                }.disabled(model.committing || selection == nil || isCurrent)
            }
            List(selection: $selection) {
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo").frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("苹果系统翻译"))
                        Text(L10n.tr("内置服务")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ModelUsageLabel(supportsAssistance: false)
                    if store.selectedID == nil { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel(L10n.tr("默认翻译")) }
                }.padding(.vertical, 3).tag("apple")
                ForEach(store.configurations) { service in
                    HStack(spacing: 10) {
                        Image(systemName: "network").frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.name).lineLimit(1)
                            Text("\(service.adapter == .openAICompatible ? service.model : service.adapter.name) · \(URL(string: service.baseURL)?.host ?? "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        ModelUsageLabel(supportsAssistance: service.isRemoteModelAPI)
                        if store.selectedID == service.id { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel(L10n.tr("默认翻译")) }
                    }.padding(.vertical, 3).tag(service.id.uuidString).help(service.baseURL)
                }
            }.listStyle(.inset).frame(minHeight: 200)
            HStack(spacing: 10) {
                Button(L10n.tr("添加…"), systemImage: "plus") { editing = TranslationServiceConfiguration() }
                Button(L10n.tr("编辑…")) { editing = selected }.disabled(selected == nil)
                Button(L10n.tr("删除"), role: .destructive) { confirmingDelete = true }.disabled(selected == nil)
                Spacer()
            }.disabled(model.committing)
            Divider()
            HStack(spacing: 10) {
                Button(L10n.tr("导入…")) { importing = true }.disabled(model.committing)
                Menu(L10n.tr("导出")) {
                    Button(L10n.tr("导出选中配置…")) { if let selected { prepareExport(ids: [selected.id]) } }.disabled(selected == nil)
                    Button(L10n.tr("导出全部自定义配置…")) { prepareExport(ids: nil) }.disabled(store.configurations.isEmpty)
                }.frame(width: 84).disabled(store.configurations.isEmpty)
                Spacer()
                Text(L10n.tr("\(store.configurations.count) 个自定义配置")).font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(isError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if !store.issue.isEmpty { Text(store.issue).font(.callout).foregroundStyle(.red) }
        }
        .padding(20).frame(minWidth: 520, minHeight: 380)
        .onAppear { selection = store.selectedID?.uuidString ?? "apple" }
        .onChange(of: store.selectedID) { _, value in selection = value?.uuidString ?? "apple" }
        .sheet(item: $editing) { configuration in
            ServiceEditorView(model: model, store: store, configuration: configuration)
        }
        .confirmationDialog(L10n.tr("删除“\(selected?.name ?? "")”？"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(L10n.tr("删除配置"), role: .destructive) {
                if let id = selected?.id { perform { try store.remove(id); selection = "apple" } }
            }
        } message: { Text(L10n.tr("此服务的配置和已保存密钥将被删除。")) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= TranslationServicePackage.maximumBytes else {
                    throw ServiceConfigurationFailure.oversized
                }
                let count = try store.importPackage(Data(contentsOf: url))
                message = count == 0 ? L10n.tr("配置已存在，未重复导入。") : L10n.tr("已导入 \(count) 个服务，当前服务保持不变。")
                isError = false
            } catch { message = error.localizedDescription; isError = true }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: L10n.tr("Poieva Translate 模型配置")) { result in
            switch result {
            case .success: message = L10n.tr("配置已导出，不包含密钥。"); isError = false
            case let .failure(error): message = error.localizedDescription; isError = true
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); message = ""; isError = false }
        catch { message = error.localizedDescription; isError = true }
    }
    private func prepareExport(ids: Set<UUID>?) {
        perform {
            exportDocument = ServicePackageDocument(data: try store.exportPackage(ids: ids))
            exporting = true
        }
    }
}

private struct ModelUsageLabel: View {
    let supportsAssistance: Bool
    var body: some View {
        Text(supportsAssistance ? L10n.tr("用途：翻译、辅助") : L10n.tr("用途：翻译"))
            .font(.caption).foregroundStyle(.secondary).fixedSize()
    }
}

private struct ServicePackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ServiceConfigurationFailure.damagedFile }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
private struct ServiceEditorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationServiceStore
    private let originalAdapter: TranslationServiceAdapter?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TranslationServiceConfiguration
    @State private var key = ""
    @State private var clearKey = false
    @State private var parameters = ""
    @State private var httpTemplateText = ""
    @State private var error = ""
    @State private var testMessage = ""
    @State private var testFailed = false
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var testID = UUID()
    @State private var customDeepLURL = false
    @State private var advancedExpanded = false
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?

    init(model: AppModel, store: TranslationServiceStore, configuration: TranslationServiceConfiguration) {
        self.model = model; self.store = store
        originalAdapter = store.configurations.contains(where: { $0.id == configuration.id }) ? configuration.adapter : nil
        _draft = State(initialValue: configuration)
        _parameters = State(initialValue: configuration.parametersText)
        _httpTemplateText = State(initialValue: (configuration.http ?? HTTPTranslationTemplate()).jsonText)
        _customDeepLURL = State(initialValue: configuration.adapter == .deepL && ![TranslationServiceAdapter.deepL.defaultURL, "https://api-free.deepl.com/v2/translate"].contains(configuration.baseURL))
    }
    private var savedKey: Bool { store.hasKey(draft.id) }
    private var requiresNewKey: Bool {
        guard savedKey, let original = store.configurations.first(where: { $0.id == draft.id }) else { return false }
        return original.adapter != draft.adapter || original.origin != draft.origin || original.appID != draft.appID || original.http?.credentialScope != draft.http?.credentialScope
    }
    private var needsKey: Bool { draft.adapter != .customHTTP || draft.http?.authentication != HTTPTranslationAuthentication.none }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.configurations.contains { $0.id == draft.id } ? L10n.tr("编辑配置") : L10n.tr("添加配置"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConfigurationGroup {
                        HStack(alignment: .top, spacing: 16) {
                            ConfigurationField(title: L10n.tr("服务类型")) {
                                SelectionField(title: L10n.tr("服务类型"), selection: $draft.adapter,
                                    options: TranslationServiceAdapter.configurationOptions(editing: originalAdapter).map { SelectionOption($0, $0.name) })
                                    .help(draft.adapter == .openAICompatible ? L10n.tr("支持 OpenAI 兼容的 Chat Completions 接口。") : draft.adapter.name)
                            }
                            ConfigurationField(title: L10n.tr("服务名称")) {
                                ConfigurationEntry(title: L10n.tr("服务名称"), text: $draft.name, prompt: L10n.tr("自定义名称"))
                            }
                        }
                    }
                    ConfigurationGroup {
                        if draft.adapter == .deepL {
                            ConfigurationField(title: L10n.tr("API 地址")) {
                                SelectionField(title: L10n.tr("API 地址"), selection: Binding(get: {
                                    customDeepLURL ? "custom" : draft.baseURL.contains("api-free.deepl.com") ? "free" : "standard"
                                }, set: { value in
                                    customDeepLURL = value == "custom"
                                    if value == "standard" { draft.baseURL = TranslationServiceAdapter.deepL.defaultURL }
                                    if value == "free" { draft.baseURL = "https://api-free.deepl.com/v2/translate" }
                                }), options: [SelectionOption("standard", L10n.tr("标准 API")), SelectionOption("free", "API Free"), SelectionOption("custom", L10n.tr("自定义"))])
                            }
                        }
                        if draft.adapter == .openAICompatible || draft.adapter == .customHTTP || draft.adapter == .deepL && customDeepLURL {
                            ConfigurationField(title: L10n.tr("服务地址")) {
                                ConfigurationEntry(title: L10n.tr("服务地址"), text: $draft.baseURL, prompt: "https://api.example.com/v1")
                            }
                        }
                        if draft.adapter == .openAICompatible {
                            ConfigurationField(title: L10n.tr("模型名称")) {
                                ConfigurationEntry(title: L10n.tr("模型名称"), text: $draft.model, prompt: L10n.tr("服务商提供的模型 ID"))
                            }
                        }
                        if draft.adapter.needsAppID {
                            ConfigurationField(title: draft.adapter == .baidu ? "APP ID" : L10n.tr("应用 ID")) {
                                ConfigurationEntry(title: L10n.tr("应用 ID"), text: $draft.appID, prompt: L10n.tr("服务控制台中的应用 ID"))
                            }
                        }
                        if draft.adapter == .customHTTP, let template = draft.http {
                            LabeledContent(L10n.tr("鉴权方式")) { Text(template.authentication.name).foregroundStyle(.secondary) }
                                .font(.system(size: 12))
                            ForEach(template.options) { option in
                                ConfigurationField(title: option.title) {
                                    SelectionField(title: option.title, selection: Binding(get: {
                                        template.selectedValue(for: option, parameters: draft.parameters)
                                    }, set: { value in draft.parameters[option.id] = .string(value) }),
                                        options: option.choices.map { SelectionOption($0.value, $0.title) })
                                }
                            }
                        }
                        if needsKey {
                            ConfigurationField(title: draft.adapter.keyLabel) {
                                ConfigurationEntry(title: draft.adapter.keyLabel, text: $key,
                                    prompt: requiresNewKey ? L10n.tr("配置已变更，请重新填写") : savedKey ? L10n.tr("已保存，留空保持") : L10n.tr("填写自己的密钥"), secure: true)
                                    .disabled(clearKey)
                            }
                        }
                        if savedKey { Toggle(L10n.tr("清除已保存的密钥"), isOn: $clearKey).font(.system(size: 12)) }
                        Label(L10n.tr("密钥保存在本机钥匙串，导出不包含密钥"), systemImage: "lock")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        Button { withAnimation(.easeInOut(duration: 0.16)) { advancedExpanded.toggle() } } label: {
                            HStack {
                                Text(L10n.tr("高级参数")).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }.padding(14).frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(L10n.tr("高级参数"))
                            .accessibilityValue(advancedExpanded ? L10n.tr("已展开") : L10n.tr("已收起"))
                        if advancedExpanded {
                            Divider().padding(.horizontal, 14)
                            VStack(alignment: .leading, spacing: 16) { advancedFields }.padding(14)
                        }
                    }
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
                }.padding(20).disabled(saving)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if !testMessage.isEmpty { Text(testMessage).font(.system(size: 12)).foregroundStyle(testFailed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 10) {
                    Button(testing ? L10n.tr("取消测试") : L10n.tr("测试连接")) {
                        if testing { cancelTest() } else { testConnection() }
                    }.disabled(model.committing || saving)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button(saving ? L10n.tr("正在保存…") : L10n.tr("保存")) { save() }.keyboardShortcut(.defaultAction).disabled(testing || saving || model.committing)
                        .buttonStyle(.borderedProminent)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(width: 540, height: 600)
        .onChange(of: draft.adapter) { old, new in
            if draft.name.isEmpty || draft.name == old.name { draft.name = new.name }
            draft.baseURL = new.defaultURL; draft.model = ""; draft.appID = ""
            draft.jsonMode = false; draft.parameters = [:]; parameters = ""
            draft.http = new == .customHTTP ? HTTPTranslationTemplate() : nil
            httpTemplateText = (draft.http ?? HTTPTranslationTemplate()).jsonText
            key = ""; clearKey = false; customDeepLURL = false; error = ""
        }
        .onChange(of: draft) { _, _ in cancelTest() }
        .onChange(of: key) { _, _ in cancelTest() }
        .onChange(of: clearKey) { _, _ in cancelTest() }
        .onChange(of: parameters) { _, _ in cancelTest() }
        .onChange(of: httpTemplateText) { _, text in
            cancelTest()
            if draft.adapter == .customHTTP, let template = try? HTTPTranslationTemplate.parse(text) {
                draft.http = template
                draft.parameters = draft.parameters.filter { key, value in
                    guard case let .string(selected) = value else { return false }
                    return template.options.first(where: { $0.id == key })?.choices.contains(where: { $0.value == selected }) == true
                }
            }
        }
        .onDisappear { cancelTest(); saveTask?.cancel(); saveTask = nil }
    }

    @ViewBuilder private var advancedFields: some View {
        switch draft.adapter {
        case .openAICompatible:
            Toggle(L10n.tr("JSON 输出模式"), isOn: $draft.jsonMode).toggleStyle(.switch).controlSize(.small)
            ConfigurationField(title: L10n.tr("请求参数 JSON")) {
                TextEditor(text: $parameters).font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 120).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5) }
                    .accessibilityLabel(L10n.tr("高级请求参数 JSON"))
            }
        case .deepL:
            ConfigurationField(title: L10n.tr("语气")) {
                SelectionField(title: L10n.tr("语气"), selection: option("formality", defaultValue: "default"), options: formalityOptions)
            }
            ConfigurationField(title: L10n.tr("翻译模型")) {
                SelectionField(title: L10n.tr("翻译模型"), selection: option("model_type", defaultValue: ""), options: [
                    SelectionOption("", L10n.tr("服务默认")), SelectionOption("prefer_quality_optimized", L10n.tr("优先质量")),
                    SelectionOption("quality_optimized", L10n.tr("质量优先（严格）")), SelectionOption("latency_optimized", L10n.tr("优先速度"))])
            }
        case .baidu:
            ConfigurationField(title: L10n.tr("服务地址")) { ConfigurationEntry(title: L10n.tr("服务地址"), text: $draft.baseURL) }
            Toggle(L10n.tr("使用已开通的术语干预"), isOn: Binding(get: { draft.parameters["action"] == .number(1) }, set: {
                draft.parameters["action"] = $0 ? .number(1) : nil
            })).toggleStyle(.switch).controlSize(.small)
        case .youdao:
            ConfigurationField(title: L10n.tr("服务地址")) { ConfigurationEntry(title: L10n.tr("服务地址"), text: $draft.baseURL) }
            ConfigurationField(title: L10n.tr("翻译领域")) {
                SelectionField(title: L10n.tr("翻译领域"), selection: option("domain", defaultValue: "general"), options: [
                    SelectionOption("general", L10n.tr("通用")), SelectionOption("computers", L10n.tr("计算机")), SelectionOption("medicine", L10n.tr("医学")),
                    SelectionOption("finance", L10n.tr("金融")), SelectionOption("game", L10n.tr("游戏"))])
            }
            ConfigurationField(title: L10n.tr("术语表 ID（可选）")) {
                ConfigurationEntry(title: L10n.tr("术语表 ID"), text: option("vocabId", defaultValue: ""))
            }
        case .customHTTP:
            ConfigurationField(title: L10n.tr("接口模板 JSON")) {
                TextEditor(text: $httpTemplateText).font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).frame(height: 320).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5) }
                    .accessibilityLabel(L10n.tr("HTTP 接口模板 JSON"))
                    .help(L10n.tr("POST JSON；占位符为 {{text}}、{{source}}、{{target}} 和 {{option.名称}}。密钥只填写在密钥栏。"))
            }
        }
    }

    private var formalityOptions: [SelectionOption<String>] {
        var options = [SelectionOption("default", L10n.tr("默认")), SelectionOption("prefer_more", L10n.tr("偏正式")), SelectionOption("prefer_less", L10n.tr("偏自然"))]
        if case let .string(value) = draft.parameters["formality"], ["more", "less"].contains(value) {
            options.append(SelectionOption(value, value == "more" ? L10n.tr("正式（严格）") : L10n.tr("自然（严格）")))
        }
        return options
    }

    private func validatedDraft() throws -> TranslationServiceConfiguration {
        var result = draft
        if draft.adapter == .openAICompatible { result.parameters = try TranslationServiceConfiguration.parseParameters(parameters) }
        if draft.adapter == .customHTTP { result.http = try HTTPTranslationTemplate.parse(httpTemplateText) }
        return try result.validated()
    }
    private func option(_ name: String, defaultValue: String) -> Binding<String> {
        Binding(get: {
            if case let .string(value) = draft.parameters[name] { return value }
            return defaultValue
        }, set: { value in draft.parameters[name] = value.isEmpty || value == defaultValue ? nil : .string(value) })
    }
    private func save() {
        guard !saving else { return }
        do {
            let configuration = try validatedDraft()
            let provided = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.validateCredentialReuse(configuration, providedKey: provided, clearKey: clearKey)
            saving = true; error = ""; testMessage = ""
            saveTask = Task { @MainActor in
                do {
                    try await store.prepareCredentialForSave(configuration, key: provided, clearKey: clearKey)
                    try Task.checkCancellation()
                    try store.save(configuration, key: provided, clearKey: clearKey)
                    dismiss()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                saving = false; saveTask = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    private func cancelTest() {
        testID = UUID(); testTask?.cancel(); testTask = nil; testing = false; testMessage = ""
    }
    private func testConnection() {
        do {
            let configuration = try validatedDraft()
            let provided = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.validateCredentialReuse(configuration, providedKey: provided, clearKey: clearKey)
            let credential = clearKey ? nil : !provided.isEmpty ? provided : try store.key(for: configuration.id)
            let provider = try TranslationServiceFactory.make(configuration: configuration, credential: { credential })
            let id = UUID(); testID = id; testing = true; testMessage = ""; error = ""
            testTask = Task { @MainActor in
                do {
                    _ = try await provider.translate(TranslationRequest(text: "Hello.", source: .english, target: .simplifiedChinese))
                    guard testID == id, !Task.isCancelled else { return }
                    testMessage = L10n.tr("连接成功，测试翻译已通过。"); testFailed = false
                } catch {
                    guard testID == id, !Task.isCancelled else { return }
                    testMessage = error.localizedDescription; testFailed = true
                }
                testing = false; testTask = nil
            }
        } catch { self.error = error.localizedDescription }
    }
}

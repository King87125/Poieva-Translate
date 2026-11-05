import SwiftUI
import TypeBridgeCore

@MainActor
struct SpeechServiceManagementView: View {
    @ObservedObject var store: SpeechServiceStore
    @State private var selection: UUID?
    @State private var editing: SpeechServiceConfiguration?
    @State private var deleting = false
    @State private var error = ""
    private var selected: SpeechServiceConfiguration? { store.configurations.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("用于实时字幕的语音识别 API")).font(.callout).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(store.configurations) { value in
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value.name)
                            Text("\(value.model) · \(URL(string: value.baseURL)?.host ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L10n.tr("用途：语音识别")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(value.id)
                }
            }.listStyle(.inset).frame(minHeight: 160)
                .overlay { if store.configurations.isEmpty { Text(L10n.tr("添加自己的识别服务，开始使用实时字幕。")).foregroundStyle(.secondary).allowsHitTesting(false) } }
            HStack(spacing: 10) {
                Button(L10n.tr("添加…"), systemImage: "plus") {
                    editing = .init(name: SpeechServiceKind.alibabaQwen.name, baseURL: SpeechServiceKind.alibabaQwen.defaultBaseURL,
                                    model: SpeechServiceKind.alibabaQwen.defaultModel, kind: .alibabaQwen)
                }
                Button(L10n.tr("编辑…")) { editing = selected }.disabled(selected == nil)
                Button(L10n.tr("删除"), role: .destructive) { deleting = true }.disabled(selected == nil)
                Spacer()
            }
            Text(L10n.tr("支持阿里云千问和 Realtime 转写兼容接口。密钥保存在本机钥匙串。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !error.isEmpty || !store.issue.isEmpty { Text(error.isEmpty ? store.issue : error).font(.caption).foregroundStyle(.red) }
        }.padding(20)
        .sheet(item: $editing) { SpeechServiceEditor(store: store, configuration: $0) }
        .confirmationDialog(L10n.tr("删除“\(selected?.name ?? "")”？"), isPresented: $deleting, titleVisibility: .visible) {
            Button(L10n.tr("删除配置"), role: .destructive) {
                do { if let selection { try store.remove(selection) }; selection = nil; error = "" }
                catch { self.error = error.localizedDescription }
            }
        } message: { Text(L10n.tr("此服务的配置和已保存密钥将被删除。")) }
    }
}

@MainActor
private struct SpeechServiceEditor: View {
    @ObservedObject var store: SpeechServiceStore
    @Environment(\.dismiss) private var dismiss
    @State var configuration: SpeechServiceConfiguration
    @State private var key = ""
    @State private var clearKey = false
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false
    @State private var task: Task<Void, Never>?
    @State private var socket: RealtimeTranscriber?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text(L10n.tr("语音识别配置")).font(.title3.weight(.semibold)); Spacer()
                Text(configuration.kind.name).font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConfigurationGroup {
                        ConfigurationField(title: L10n.tr("服务类型")) {
                            SelectionField(title: L10n.tr("语音识别服务类型"), selection: $configuration.kind,
                                options: SpeechServiceKind.allCases.map { SelectionOption($0, $0.name) })
                        }
                        ConfigurationField(title: L10n.tr("服务名称")) { ConfigurationEntry(title: L10n.tr("服务名称"), text: $configuration.name, prompt: L10n.tr("自定义名称")) }
                        if configuration.kind == .alibabaQwen {
                            ConfigurationField(title: L10n.tr("服务地域")) {
                                SelectionField(title: L10n.tr("识别服务地域"), selection: qwenRegion,
                                    options: [SelectionOption("beijing", L10n.tr("北京")), SelectionOption("singapore", L10n.tr("新加坡")), SelectionOption("custom", L10n.tr("自定义地址"))])
                            }
                        }
                        ConfigurationField(title: L10n.tr("识别服务地址")) {
                            ConfigurationEntry(title: L10n.tr("识别服务地址"), text: $configuration.baseURL, prompt: "wss://api.example.com/v1/realtime")
                        }
                        ConfigurationField(title: L10n.tr("识别模型")) {
                            ConfigurationEntry(title: L10n.tr("识别模型"), text: $configuration.model, prompt: L10n.tr("服务商提供的转写模型 ID"))
                        }
                    }
                    ConfigurationGroup {
                        ConfigurationField(title: L10n.tr("密钥（可选）")) {
                            ConfigurationEntry(title: L10n.tr("识别服务密钥"), text: $key,
                                prompt: store.hasKey(configuration.id) ? L10n.tr("已保存，留空则保留") : L10n.tr("填写自己的密钥"), secure: true)
                        }
                        if store.hasKey(configuration.id) { Toggle(L10n.tr("清除已保存的密钥"), isOn: $clearKey) }
                    }
                    Text(configuration.kind == .alibabaQwen ? L10n.tr("填写所选地域的百炼 API Key。北京与新加坡的密钥不能混用，也可填写业务空间专属地址。") : L10n.tr("请使用兼容 Realtime 转写的语音 API，填写服务商提供的地址和转写模型。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if configuration.kind == .alibabaQwen {
                        Link(L10n.tr("阿里云接入说明"), destination: URL(string: "https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-interaction-process")!).font(.caption)
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(20).disabled(busy)
            }
            Divider()
            HStack {
                Button(L10n.tr("检查连接")) { check() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.tr("取消")) { task?.cancel(); socket?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy)
            }.padding(16)
        }.frame(width: 560, height: 570)
        .onChange(of: configuration.kind) { old, new in
            if configuration.name.isEmpty || configuration.name == old.name { configuration.name = new.name }
            if configuration.baseURL.isEmpty || configuration.baseURL == old.defaultBaseURL { configuration.baseURL = new.defaultBaseURL }
            if configuration.model.isEmpty || configuration.model == old.defaultModel { configuration.model = new.defaultModel }
            message = ""
        }
        .onDisappear { task?.cancel(); socket?.cancel(); key = "" }
    }
    private var qwenRegion: Binding<String> {
        Binding(get: {
            switch configuration.baseURL {
            case "wss://dashscope.aliyuncs.com/api-ws/v1/realtime": return "beijing"
            case "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime": return "singapore"
            default: return "custom"
            }
        }, set: { value in
            if value == "beijing" { configuration.baseURL = SpeechServiceKind.alibabaQwen.defaultBaseURL }
            if value == "singapore" { configuration.baseURL = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime" }
        })
    }
    private func check() {
        busy = true; message = ""; failed = false
        task = Task { @MainActor in
            defer { busy = false; socket?.cancel(); socket = nil }
            do {
                let configuration = try configuration.validated()
                let credential = try store.keyForTest(configuration, key: key, clear: clearKey)
                let socket = RealtimeTranscriber(); self.socket = socket
                try await socket.connect(configuration: configuration, key: credential)
                try Task.checkCancellation()
                message = L10n.tr("连接成功，转写会话已就绪。此检查不采集声音。")
            } catch { if !Task.isCancelled { message = error.localizedDescription; failed = true } }
        }
    }
    private func save() {
        busy = true; message = ""
        task = Task { @MainActor in
            defer { busy = false }
            do {
                try await store.prepareForSave(configuration, key: key, clear: clearKey)
                try Task.checkCancellation()
                try store.save(configuration, key: key, clear: clearKey); key = ""; dismiss()
            } catch { if !Task.isCancelled { message = error.localizedDescription; failed = true } }
        }
    }
}

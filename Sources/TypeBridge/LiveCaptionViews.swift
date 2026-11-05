import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TypeBridgeCore

@MainActor
struct LiveCaptionSettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: LiveCaptionModel
    @ObservedObject var settings: CaptionSettings
    @ObservedObject var speech: SpeechServiceStore
    @ObservedObject var translations: TranslationServiceStore
    @State private var applications: [SelectionOption<String>] = []
    @State private var importing = false
    @State private var fileError = ""
    private var validTranslator: Bool { settings.translationID == "apple" || translations.configurations.contains { $0.id.uuidString == settings.translationID } }
    private var validRecognizer: Bool { speech.configurations.contains { $0.id == settings.speechID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("实时字幕")).font(.title3.weight(.semibold))
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("预览提词器")) { model.preview() }.disabled(model.isActive)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConfigurationGroup {
                        ConfigurationField(title: L10n.tr("识别声音")) {
                            SelectionField(title: L10n.tr("字幕采音方式"), selection: $settings.audioInput,
                                options: CaptionAudioInput.allCases.map { SelectionOption($0, $0.name) })
                        }
                        if settings.audioInput != .microphone {
                        HStack(alignment: .bottom, spacing: 12) {
                            ConfigurationField(title: L10n.tr("声音来源")) {
                                SelectionField(title: L10n.tr("字幕声音来源"), selection: $settings.audioBundleID, options: applications)
                            }
                            Button { refreshApplications() } label: { Image(systemName: "arrow.clockwise") }.help(L10n.tr("刷新应用列表"))
                        }
                        }
                        Text(settings.audioInput == .both ? L10n.tr("两路声音分别识别，可能分别计费。") : L10n.tr("仅开启所选声音的一路识别连接。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.isActive)
                    ConfigurationGroup {
                        HStack(alignment: .bottom, spacing: 12) {
                            ConfigurationField(title: L10n.tr("语音识别")) {
                                SelectionField(title: L10n.tr("字幕识别服务"), selection: $settings.speechID,
                                    options: [SelectionOption<UUID?>(nil, L10n.tr("选择识别 API"))] + speech.configurations.map { SelectionOption(Optional($0.id), $0.name) })
                            }
                            Button(L10n.tr("配置…")) { app.showSpeechServices() }
                        }
                        ConfigurationField(title: L10n.tr("翻译服务")) {
                            SelectionField(title: L10n.tr("字幕翻译服务"), selection: $settings.translationID,
                                options: [SelectionOption("apple", L10n.tr("苹果系统翻译"))] + translations.configurations.map { SelectionOption($0.id.uuidString, $0.name) })
                        }
                        HStack(spacing: 12) {
                            SelectionField(title: L10n.tr("字幕原文语言"), selection: $settings.source,
                                options: AppLanguage.allCases.map { SelectionOption($0, $0.name) })
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            SelectionField(title: L10n.tr("字幕目标语言"), selection: $settings.target,
                                options: AppLanguage.targets.map { SelectionOption($0, $0.name) })
                        }
                        Text(L10n.tr("翻译沿用当前场景的术语和语气。上下文开启时，仅使用之前的字幕作参考。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.isActive)
                    ConfigurationGroup {
                        HStack { Text(L10n.tr("顶部提词器")); Spacer(); Toggle(L10n.tr("显示原文"), isOn: $settings.showOriginal).toggleStyle(.switch).controlSize(.small) }
                        HStack(spacing: 12) {
                            Text(L10n.tr("字幕字号")); Slider(value: $settings.fontSize, in: 18...30, step: 1)
                            Text("\(Int(settings.fontSize))").monospacedDigit().foregroundStyle(.secondary).frame(width: 30)
                        }
                        SelectionField(title: L10n.tr("字幕显示屏"), selection: $settings.screenID,
                            options: [SelectionOption("", L10n.tr("主显示屏"))] + NSScreen.screens.map { SelectionOption(String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0), $0.localizedName) })
                    }
                    Text(L10n.tr("开始后，声音会发送至所选识别服务，文字会发送至所选翻译服务。音频和字幕不写入历史；暂停会关闭采音与识别连接。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !model.error.isEmpty || !fileError.isEmpty { Text(fileError.isEmpty ? model.error : fileError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let service = speech.configurations.first(where: { $0.id == settings.speechID }) {
                    Text(L10n.tr("音频发送至：\(service.name)") + " · " + model.audioDescription)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 12) {
                Menu(L10n.tr("测试")) {
                    Button(L10n.tr("预览提词器（不联网）")) { model.preview() }
                    Button(L10n.tr("测试音频文件…")) { importing = true }.disabled(!validRecognizer || !validTranslator)
                }.disabled(model.isActive)
                Spacer()
                if model.isActive {
                    Button(L10n.tr("暂停")) { model.pause() }
                    Button(L10n.tr("停止")) { model.stop() }
                } else {
                    if model.islandVisible { Button(L10n.tr("关闭提词器")) { model.stop() } }
                    Button(L10n.tr("开始字幕")) { fileError = ""; model.start() }.buttonStyle(.borderedProminent)
                        .disabled(!validRecognizer || !validTranslator)
                }
                }
            }.padding(16)
        }.frame(minWidth: 580, minHeight: 600)
        .onAppear { refreshApplications() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.wav, .aiff, .mpeg4Audio, .mp3]) { result in
            switch result {
            case .success(let url): fileError = ""; model.start(file: url)
            case .failure(let error): if (error as? CocoaError)?.code != .userCancelled { fileError = error.localizedDescription }
            }
        }
    }
    private func refreshApplications() {
        applications = [SelectionOption("", L10n.tr("全部系统声音"))]
        var seen: Set<String> = []
        for app in NSWorkspace.shared.runningApplications.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            applications.append(.init(id, app.localizedName ?? id))
        }
        if !settings.audioBundleID.isEmpty, !seen.contains(settings.audioBundleID) { applications.append(.init(settings.audioBundleID, L10n.tr("来源未运行"))) }
    }
}

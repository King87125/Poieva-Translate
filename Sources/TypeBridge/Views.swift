import AppKit
import SwiftUI
import Translation
import TypeBridgeCore

@MainActor
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var body: some View { WorkbenchView(model: model, settings: settings) }
}

@MainActor
struct WorkbenchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var editingContext = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SelectionField(title: L10n.tr("翻译方式"), selection: $settings.inputDirection,
                    options: TranslationDirection.allCases.map { SelectionOption($0, $0.name) }).frame(width: L10n.language == .english ? 158 : 142)
                if settings.inputDirection == .fixedTarget {
                    SelectionField(title: L10n.tr("原文语言"), selection: $model.sourceLanguage,
                        options: AppLanguage.allCases.map { SelectionOption($0, $0.name) }).frame(width: L10n.language == .english ? 160 : 100)
                    Button { model.swapLanguages() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("交换语言")).accessibilityLabel(L10n.tr("交换语言"))
                        .frame(width: 22)
                    SelectionField(title: L10n.tr("目标语言"), selection: $settings.inputTarget,
                        options: AppLanguage.targets.map { SelectionOption($0, $0.name) }).frame(width: L10n.language == .english ? 160 : 100)
                }
                Spacer(minLength: 8)
                WorkbenchServiceChooser(model: model, store: model.services).frame(width: L10n.language == .english ? 190 : 180)
            }
            .padding(.horizontal, 24).frame(height: 44)
            .disabled(model.translatingOutsideWorkbench || model.preparing || model.isComposing)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text(L10n.tr("原文")).font(.system(size: 13, weight: .medium))
                            Text(sourceLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(model.contextBefore.isEmpty && model.contextAfter.isEmpty ? L10n.tr("上下文…") : L10n.tr("上下文 · 已添加")) { editingContext = true }
                                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                                .disabled(model.translatingOutsideWorkbench || model.isComposing)
                            Button(L10n.tr("清空")) { model.clearWorkbench() }
                                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                                .disabled(model.translatingOutsideWorkbench || (model.sourceText.isEmpty && !model.isComposing))
                        }.padding(.horizontal, 24).frame(height: 44)
                        PlainTextEditor(text: model.sourceText, editable: !model.translatingOutsideWorkbench,
                            revision: model.workbenchEditorRevision,
                            onEdit: { text, composing in model.workbenchTextChanged(text, isComposing: composing) })
                            .accessibilityLabel(L10n.tr("原文输入框"))
                    }.frame(width: max(280, geometry.size.width * 0.5), height: geometry.size.height)
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45)).frame(width: 0.5)
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text(L10n.tr("译文")).font(.system(size: 13, weight: .medium))
                            Text(model.resultLanguage?.name ?? (settings.inputDirection == .fixedTarget ? settings.inputTarget.name : ""))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            if !model.isComparing {
                                Button(L10n.tr("复制")) { model.copyWorkbenchResult() }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                                    .disabled(model.resultText.isEmpty || model.busy)
                            }
                        }.padding(.horizontal, 24).frame(height: 44)
                        if model.isComparing {
                            ComparisonResultsView(model: model, controller: model.comparisons, settings: settings)
                        } else {
                            ScrollView {
                                Text(model.resultText).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel(L10n.tr("译文"))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            HStack(spacing: 12) {
                Text(L10n.tr("\(model.sourceText.count) 字")).monospacedDigit()
                    .foregroundStyle(model.sourceText.count > 20_000 ? Color.red : Color.secondary)
                if !model.isComparing {
                    if model.busy, let state = model.feedback {
                        InlineFeedbackView(state: state, style: settings.feedbackStyle, animates: model.workbenchVisible)
                    } else if model.isError, !model.message.isEmpty {
                        Text(model.message).foregroundStyle(.red).lineLimit(1).help(model.message)
                    } else if model.hasWorkbenchGuidance, let issue = model.workbenchAssistanceIssue {
                        Text(issue).foregroundStyle(.orange).lineLimit(1).help(issue)
                    } else if model.hasWorkbenchGuidance, let info = model.workbenchExecutionInfo {
                        Text(info.caption).foregroundStyle(.secondary).lineLimit(1).help(info.detail)
                    }
                }
                Spacer(minLength: 4)
                if !model.isComparing, model.feedback?.surface == .workbench, let recovery = model.feedback?.recovery {
                    Button(recovery.title) { model.recoverFromFeedback() }.buttonStyle(.link)
                }
                if model.busy {
                    Button(model.committing ? L10n.tr("正在替换") : L10n.tr("取消")) { model.cancel() }.disabled(model.committing)
                } else {
                    Text("⌘ ↵").foregroundStyle(.tertiary)
                    Button(L10n.tr("翻译")) { model.translateManually() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).controlSize(.regular)
                        .disabled(!model.hasWorkbenchServices || model.preparing || model.isComposing || model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sourceText.count > 20_000)
                }
            }
            .font(.system(size: 11)).padding(.horizontal, 24).frame(height: 52)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 680, minHeight: 360)
        .sheet(isPresented: $editingContext) { WorkbenchContextEditor(model: model) }
        .onChange(of: settings.inputDirection) { _, _ in model.scheduleWorkbenchTranslation() }
        .onChange(of: settings.inputTarget) { _, _ in model.scheduleWorkbenchTranslation() }
        .onChange(of: settings.preserveCode) { _, _ in model.scheduleWorkbenchTranslation() }
        .onChange(of: model.sourceLanguage) { _, _ in model.scheduleWorkbenchTranslation() }
    }

    private var sourceLabel: String {
        if settings.inputDirection == .fixedTarget { return model.sourceLanguage.name }
        if model.resultLanguage == .english { return L10n.tr("中文") }
        if model.resultLanguage?.isChinese == true { return L10n.tr("英文") }
        return L10n.tr("自动检测")
    }
}

/// NSTextView supplies native selection, editing, undo, accessibility and precise text insets.
@MainActor
private struct PlainTextEditor: NSViewRepresentable {
    let text: String
    let editable: Bool
    let revision: UUID
    let onEdit: (String, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let editor = WorkbenchTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .textColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 24, height: 8)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        editor.setAccessibilityLabel(L10n.tr("原文输入框"))
        editor.onEditingChange = { [weak coordinator = context.coordinator] text, composing in
            coordinator?.editingChanged(text, composing: composing)
        }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? WorkbenchTextView else { return }
        let replacingComposition = context.coordinator.revision != revision
        editor.applyModelText(text, replacingComposition: replacingComposition)
        context.coordinator.revision = revision
        if !editor.hasMarkedText() { context.coordinator.adopt(editor.string, composing: false) }
        editor.isEditable = editable
    }
    @MainActor final class Coordinator {
        var parent: PlainTextEditor
        var revision: UUID?
        private var lastText: String?
        private var lastComposing: Bool?
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func adopt(_ text: String, composing: Bool) {
            lastText = text
            lastComposing = composing
        }
        func editingChanged(_ text: String, composing: Bool) {
            guard lastText != text || lastComposing != composing else { return }
            adopt(text, composing: composing)
            parent.onEdit(text, composing)
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section(L10n.tr("通用设置")) {
                HStack {
                    Text(L10n.tr("界面语言"))
                    Spacer()
                    SelectionField(title: L10n.tr("界面语言"), selection: $settings.interfaceLanguage,
                        options: InterfaceLanguage.allCases.map { SelectionOption($0, $0.nativeName) })
                        .frame(width: 180)
                }.accessibilityElement(children: .contain)
                if settings.interfaceLanguage != L10n.language {
                    Text(L10n.tr("重新打开 Poieva Translate 后生效。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.tr("模型管理")) { ServiceSettingsSection(model: model, store: model.services) }
            Section(L10n.tr("翻译偏好")) {
                TranslationPreferenceSection(model: model, store: model.translationPreferences, services: model.services)
            }
            Section(L10n.tr("翻译方向")) {
                directionPicker(L10n.tr("翻译并替换"), selection: $settings.inputDirection)
                if settings.inputDirection == .fixedTarget {
                    languagePicker(L10n.tr("替换目标语言"), selection: $settings.inputTarget, languages: AppLanguage.targets)
                }
                directionPicker(L10n.tr("翻译预览"), selection: $settings.selectionDirection)
                if settings.selectionDirection == .fixedTarget {
                    languagePicker(L10n.tr("预览目标语言"), selection: $settings.selectionTarget, languages: AppLanguage.targets)
                }
            }
            Section(L10n.tr("快捷键")) { ShortcutSettingsSection(model: model, settings: settings) }
            Section(L10n.tr("翻译提示")) { FeedbackSettingsSection(model: model, settings: settings, animates: model.settingsVisible) }
            Section(L10n.tr("系统")) {
                HStack {
                    Text(L10n.tr("语言包"))
                    Spacer()
                    HStack(spacing: 12) {
                        Text(model.packStatus).foregroundStyle(.secondary)
                        Button(L10n.tr("管理…")) { model.showLanguagePacks() }
                    }
                }.accessibilityElement(children: .contain)
                HStack {
                    Text(L10n.tr("辅助功能"))
                    Spacer()
                    HStack(spacing: 12) {
                        Text(model.accessibilityGranted ? L10n.tr("已开启") : L10n.tr("未开启")).foregroundStyle(.secondary)
                        Button(L10n.tr("系统设置…")) { model.textAccess.requestPermission() }
                    }
                }.accessibilityElement(children: .contain)
                Toggle(L10n.tr("保留代码和链接"), isOn: $settings.preserveCode).toggleStyle(.switch).controlSize(.small)
            }
        }.formStyle(.grouped).frame(minWidth: 520, idealWidth: 560, minHeight: 540)
    }
}

@MainActor
struct LanguagePackView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                languagePicker(L10n.tr("原文语言"), selection: $model.prepareSource, languages: AppLanguage.targets).disabled(model.preparing)
                languagePicker(L10n.tr("目标语言"), selection: $model.prepareTarget, languages: AppLanguage.targets).disabled(model.preparing)
                LabeledContent(L10n.tr("状态")) { Text(model.packStatus).foregroundStyle(.secondary) }
                HStack {
                    if model.preparing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L10n.tr("刷新")) { Task { await model.refreshLanguagePack() } }.disabled(model.preparing)
                    if model.preparing { Button(L10n.tr("取消下载")) { model.cancelPreparation() } }
                    else {
                        Button(model.packInstalled ? L10n.tr("无需下载") : L10n.tr("下载语言包")) { model.prepareLanguages() }
                            .disabled(model.busy || model.packInstalled || model.prepareSource == model.prepareTarget)
                    }
                }
            }
        }
        .formStyle(.grouped).frame(minWidth: 420, minHeight: 260)
        .translationTask(model.preparationConfiguration) { session in await model.completePreparation(session) }
        .onChange(of: model.prepareSource) { _, _ in Task { await model.refreshLanguagePack() } }
        .onChange(of: model.prepareTarget) { _, _ in Task { await model.refreshLanguagePack() } }
    }
}

@MainActor
struct GuideView: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section(L10n.tr("翻译并替换")) {
                LabeledContent(L10n.tr("快捷键"), value: settings.inputShortcut.readableLabel)
                Text(L10n.tr("未选中时翻译整个输入框；选中后只替换选中部分。"))
                Text(L10n.tr("在原应用按 Command + Z 撤销替换。"))
            }
            Section(L10n.tr("翻译预览")) {
                LabeledContent(L10n.tr("快捷键"), value: settings.selectionShortcut.readableLabel)
                Text(L10n.tr("选中文字后使用快捷键，在结果窗口查看或复制译文。"))
            }
            Section(L10n.tr("使用")) {
                Text(L10n.tr("先在设置中下载语言包，并开启辅助功能权限。"))
                Text(L10n.tr("中英自动互译会将中文译为英文，将英文译为简体中文。"))
                Text(L10n.tr("读取到的文字样式随译文保留，无法确认格式时保留译文供复制。"))
                Text(L10n.tr("关闭窗口后，仍可通过菜单栏和快捷键使用。"))
            }
        }.formStyle(.grouped).textSelection(.enabled).frame(minWidth: 440, minHeight: 420)
    }
}

@MainActor
struct SelectionResultView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var showsOriginal = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selectionLanguage.name).fontWeight(.medium)
                Text(model.selectionApp).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(showsOriginal ? L10n.tr("收起原文") : L10n.tr("原文")) { showsOriginal.toggle() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 13)).padding(.bottom, 8)
            if !model.selectionGuidanceCaption.isEmpty {
                Text(model.selectionGuidanceCaption).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(model.selectionGuidanceDetail).padding(.bottom, 12)
            }
            if showsOriginal {
                ScrollView {
                    Text(model.selectionText).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100).padding(.bottom, 12)
                Divider().padding(.bottom, 12)
            }
            ScrollView {
                Text(model.selectionResult).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.selectionBusy, let state = model.feedback {
                InlineFeedbackView(state: state, style: settings.feedbackStyle, animates: model.selectionVisible).padding(.top, 12)
            }
            if !model.selectionError.isEmpty {
                Text(model.selectionError).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 12)
            }
            HStack {
                if model.feedback?.surface == .selection, let recovery = model.feedback?.recovery {
                    Button(recovery.title) { model.recoverFromFeedback() }.buttonStyle(.link)
                }
                Spacer()
                if model.selectionBusy { Button(L10n.tr("取消")) { model.cancel() } }
                else {
                    Button(copied ? L10n.tr("已复制") : L10n.tr("复制译文")) { model.copySelectionResult(); copied = true }
                        .buttonStyle(.borderedProminent).disabled(model.selectionResult.isEmpty)
                }
            }.padding(.top, 16)
        }
        .padding(20).background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity, minHeight: 260, idealHeight: 276, maxHeight: .infinity)
        .onChange(of: model.selectionResult) { _, _ in copied = false }
    }
}

@MainActor
func languagePicker(_ label: String, selection: Binding<AppLanguage>, languages: [AppLanguage]) -> some View {
    HStack {
        Text(label)
        Spacer()
        SelectionField(title: label, selection: selection, options: languages.map { SelectionOption($0, $0.name) }).frame(width: 180)
    }.accessibilityElement(children: .contain)
}

@MainActor
private func directionPicker(_ label: String, selection: Binding<TranslationDirection>) -> some View {
    HStack {
        Text(label)
        Spacer()
        SelectionField(title: label, selection: selection, options: TranslationDirection.allCases.map { SelectionOption($0, $0.name) }).frame(width: 180)
    }.accessibilityElement(children: .contain)
}

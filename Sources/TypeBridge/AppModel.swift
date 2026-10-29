import AppKit
import Combine
import SwiftUI
import Translation
import TypeBridgeCore

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet { InterfaceLanguagePreference(defaults: defaults).save(interfaceLanguage) }
    }
    @Published var inputTarget: AppLanguage { didSet { defaults.set(inputTarget.rawValue, forKey: "inputTarget") } }
    @Published var selectionTarget: AppLanguage { didSet { defaults.set(selectionTarget.rawValue, forKey: "selectionTarget") } }
    @Published var inputDirection: TranslationDirection { didSet { defaults.set(inputDirection.rawValue, forKey: "inputDirection") } }
    @Published var selectionDirection: TranslationDirection { didSet { defaults.set(selectionDirection.rawValue, forKey: "selectionDirection") } }
    @Published var preserveCode: Bool { didSet { defaults.set(preserveCode, forKey: "preserveCode") } }
    @Published var inputShortcut: KeyboardShortcut { didSet { save(inputShortcut, key: "inputShortcut") } }
    @Published var selectionShortcut: KeyboardShortcut { didSet { save(selectionShortcut, key: "selectionShortcut") } }
    @Published var feedbackStyle: FeedbackStyle { didSet { defaults.set(feedbackStyle.rawValue, forKey: "feedbackStyle") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interfaceLanguage = InterfaceLanguagePreference(defaults: defaults).effectiveLanguage
        inputTarget = AppLanguage(rawValue: defaults.string(forKey: "inputTarget") ?? "") ?? .english
        selectionTarget = AppLanguage(rawValue: defaults.string(forKey: "selectionTarget") ?? "") ?? .simplifiedChinese
        inputDirection = TranslationDirection(rawValue: defaults.string(forKey: "inputDirection") ?? "") ?? .chineseEnglish
        selectionDirection = TranslationDirection(rawValue: defaults.string(forKey: "selectionDirection") ?? "") ?? .chineseEnglish
        preserveCode = defaults.object(forKey: "preserveCode") as? Bool ?? true
        inputShortcut = Self.load("inputShortcut", defaults: defaults) ?? .inputDefault
        selectionShortcut = Self.load("selectionShortcut", defaults: defaults) ?? .selectionDefault
        feedbackStyle = FeedbackStyle(rawValue: defaults.string(forKey: "feedbackStyle") ?? "") ?? .waves
    }

    var inputTargetLabel: String { inputDirection.targetLabel(inputTarget) }
    var selectionTargetLabel: String { selectionDirection.targetLabel(selectionTarget) }

    private static func load(_ key: String, defaults: UserDefaults) -> KeyboardShortcut? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyboardShortcut.self, from: $0) }
    }

    private func save(_ shortcut: KeyboardShortcut, key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let textAccess = TextAccess()
    let hotKeys = HotKeyManager()
    let services = TranslationServiceStore(defaults: .standard, credentials: KeychainTranslationCredentials())
    let translationPreferences = TranslationPreferenceStore(defaults: .standard)
    lazy var translationProfiles = TranslationProfileStore(defaults: .standard, legacyPreferences: translationPreferences.settings.preferences)
    @Published var contextBefore = ""
    @Published var contextAfter = ""
    private var provider: any TranslationProvider = AppleTranslationProvider()
    @Published var sourceLanguage: AppLanguage = .automatic
    @Published var sourceText = ""
    @Published private(set) var isComposing = false
    @Published private(set) var workbenchEditorRevision = UUID()
    @Published var resultText = ""
    @Published var resultLanguage: AppLanguage?
    @Published private(set) var workbenchExecutionInfo: TranslationExecutionInfo?
    @Published var busy = false
    @Published private(set) var committing = false
    @Published var message = ""
    @Published var isError = false
    @Published var accessibilityGranted = false
    @Published var selectionText = ""
    @Published var selectionResult = ""
    @Published var selectionApp = ""
    @Published var selectionLanguage = AppLanguage.simplifiedChinese
    @Published var selectionBusy = false
    @Published var selectionError = ""
    @Published var selectionTitle = L10n.tr("选中翻译")
    @Published private(set) var selectionContextStatus: ContextReadStatus?
    @Published private(set) var selectionExecutionInfo: TranslationExecutionInfo?
    var selectionGuidanceCaption: String {
        if let info = selectionExecutionInfo {
            if info.hasContext { return info.caption }
            return [selectionContextStatus?.title, info.routeLabel].compactMap { $0 }.joined(separator: " · ")
        }
        return selectionContextStatus?.title ?? ""
    }
    var selectionGuidanceDetail: String {
        [selectionContextStatus?.detail, selectionExecutionInfo?.detail].compactMap { $0 }.joined(separator: " ")
    }
    @Published var prepareSource: AppLanguage = .simplifiedChinese
    @Published var prepareTarget: AppLanguage = .english
    @Published var packStatus = L10n.tr("正在检查语言包…")
    @Published var packInstalled = false
    @Published var preparing = false
    @Published var preparationConfiguration: TranslationSession.Configuration?
    @Published var shortcutMessage = ""
    @Published private(set) var feedback: TranslationFeedback?
    @Published var workbenchVisible = true
    @Published var settingsVisible = false
    @Published var selectionVisible = false
    @Published private(set) var comparisonIDs: [String] = []
    @Published private(set) var hasWorkbenchServices = true
    var isComparing: Bool { comparisonIDs.count > 1 }
    var workbenchServiceChoices: [WorkbenchServiceChoice] {
        [WorkbenchServiceChoice(id: "apple", name: L10n.tr("苹果系统翻译"))] + services.configurations.map { .init(id: $0.id.uuidString, name: $0.name) }
    }
    var workbenchServiceIDs: [String] { hasWorkbenchServices ? (isComparing ? comparisonIDs : [services.selectedID?.uuidString ?? "apple"]) : [] }
    var workbenchAssistanceIssue: String? {
        let needsHelper = workbenchServiceIDs.contains { id in
            id == "apple" || services.configurations.first(where: { $0.id.uuidString == id })?.adapter != .openAICompatible
        }
        guard needsHelper else { return nil }
        switch translationPreferences.settings.assistant {
        case "off": return L10n.tr("苹果及专业翻译需选择辅助模型，才能使用上下文与偏好。")
        default:
            return services.configurations.contains { $0.id.uuidString == translationPreferences.settings.assistant && $0.isRemoteModelAPI }
                ? nil : L10n.tr("请在翻译偏好中重新选择远程 AI API。")
        }
    }
    var hasWorkbenchGuidance: Bool { workbenchInput.guidance != nil }
    lazy var comparisons: WorkbenchComparisonController = {
        let controller = WorkbenchComparisonController(makeProvider: { [weak self] id in
            self?.workbenchProvider(id) ?? UnavailableTranslationProvider(error: ServiceConfigurationFailure.damagedFile)
        })
        controller.onChange = { [weak self] in self?.receiveComparisonChange() }
        return controller
    }()
    var onShowWindow: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowLanguagePacks: (() -> Void)?
    var onShowServices: (() -> Void)?
    var onShowProfiles: (() -> Void)?
    var onShowSelection: (() -> Void)?
    var onFeedback: (() -> Void)?
    var onPreviewFeedback: ((TranslationFeedback) -> Void)?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var permissionTimer: Timer?
    private var packRevision = UUID()
    private var preparationID = UUID()
    private var preparationSession: TranslationSession?
    private var editingShortcut = false
    private var workbenchContent: TranslatedContent?
    private var selectionContent: TranslatedContent?
    private var lastGlobalAction: ShortcutAction?
    private lazy var liveTranslation: LiveTranslationController = {
        let controller = LiveTranslationController(provider: provider)
        controller.onEvent = { [weak self] event in self?.receiveWorkbenchEvent(event) }
        return controller
    }()

    var translatingOutsideWorkbench: Bool { busy && feedback?.surface != .workbench }

    private var workbenchInput: WorkbenchTranslationInput {
        WorkbenchTranslationInput(text: sourceText, direction: settings.inputDirection, source: sourceLanguage,
            target: settings.inputTarget, preserveCode: settings.preserveCode,
            guidance: guidance(context: .init(before: contextBefore, after: contextAfter)))
    }

    init() {
        let migrated = translationPreferences.settings.usingRemoteAPIs(in: services.configurations)
        if migrated != translationPreferences.settings { try? translationPreferences.save(migrated) }
        services.canModify = { [weak self] in self?.committing == false }
        translationPreferences.canModify = { [weak self] in self?.committing == false }
        translationPreferences.onChange = { [weak self] in self?.changeTranslationService() }
        translationProfiles.canModify = { [weak self] in self?.committing == false }
        translationProfiles.onChange = { [weak self] in self?.changeTranslationService() }
        provider = configuredProvider()
        services.onActiveServiceChange = { [weak self] in self?.changeTranslationService() }
        services.onConfigurationChange = { [weak self] id in
            guard let self else { return }
            if self.translationPreferences.settings.assistant == id.uuidString { self.changeTranslationService() }
            else if self.comparisonIDs.contains(id.uuidString) { self.refreshComparison(force: true) }
        }
    }

    private func configuredProvider() -> any TranslationProvider {
        workbenchProvider(services.selectedID?.uuidString ?? "apple")
    }

    private func workbenchProvider(_ id: String) -> any TranslationProvider {
        if id == "apple" { return assisted(AppleTranslationProvider()) }
        guard let configuration = services.configurations.first(where: { $0.id.uuidString == id }) else {
            return UnavailableTranslationProvider(error: ServiceConfigurationFailure.invalid(L10n.tr("此服务已移除，请重新选择。")))
        }
        do {
            let base = try TranslationServiceFactory.make(configuration: configuration, credential: { [weak services] in
                guard let services else { throw ServiceConfigurationFailure.credential }
                return try services.key(for: configuration.id)
            })
            return assisted(base)
        } catch { return UnavailableTranslationProvider(error: error) }
    }

    private func assisted(_ base: any TranslationProvider) -> any TranslationProvider {
        let helperID = translationPreferences.settings.assistant
        return AssistedTranslationProvider(base: base, makeAssistant: { [weak services] in
            if helperID == "off" { return nil }
            guard let services, let configuration = services.configurations.first(where: { $0.id.uuidString == helperID }),
                  configuration.isRemoteModelAPI else {
                throw TranslationAssistanceFailure.unavailable(L10n.tr("请在翻译偏好中选择远程 AI API；本机辅助模型已停用。"))
            }
            return try CompatibleTranslationAssistant(configuration: configuration, credential: { [weak services] in
                guard let services else { throw ServiceConfigurationFailure.credential }
                return try services.key(for: configuration.id)
            })
        })
    }

    private func guidance(context: TranslationContext, settings: TranslationAssistanceSettings? = nil,
                          profile: TranslationProfileSnapshot? = nil, capturedProfile: Bool = false) -> TranslationGuidance? {
        let settings = settings ?? translationPreferences.settings
        let guidance = TranslationGuidance(context: settings.useContext ? context : .init(),
            profile: capturedProfile ? profile : translationProfiles.catalog.snapshot)
        return guidance.isEmpty ? nil : guidance
    }

    func updateWorkbenchContext(before: String, after: String) {
        let context = TranslationContext(before: before, after: after)
        contextBefore = context.before; contextAfter = context.after
        scheduleWorkbenchTranslation()
    }

    private func changeTranslationService() {
        if preparing { cancelPreparation() }
        liveTranslation.suspend()
        operationID = UUID()
        operation?.cancel()
        provider.cancel()
        operation = nil
        busy = false
        selectionBusy = false
        feedback = nil
        message = ""
        isError = false
        resultText = ""
        resultLanguage = nil
        workbenchExecutionInfo = nil
        workbenchContent = nil
        onFeedback?()
        provider = configuredProvider()
        let controller = LiveTranslationController(provider: provider)
        controller.onEvent = { [weak self] event in self?.receiveWorkbenchEvent(event) }
        liveTranslation = controller
        // Selection explicitly chooses this service. Imports never call this path.
        if isComparing { refreshComparison(force: true) } else { scheduleWorkbenchTranslation() }
    }

    func useWorkbenchServices(_ ids: [String]) {
        guard !committing, !translatingOutsideWorkbench else { return }
        let available = Set(workbenchServiceChoices.map(\.id))
        var seen = Set<String>()
        let ids = ids.filter { available.contains($0) && seen.insert($0).inserted }
        hasWorkbenchServices = !ids.isEmpty
        guard !ids.isEmpty else {
            comparisonIDs = []
            liveTranslation.suspend(); comparisons.suspend(clearResults: true)
            clearWorkbenchFeedback()
            return
        }
        if ids.count == 1 {
            comparisonIDs = []; comparisons.suspend(clearResults: true)
            let selection = ids[0] == "apple" ? nil : UUID(uuidString: ids[0])
            do {
                let wasSame = services.selectedID == selection
                try services.select(selection)
                if wasSame { clearWorkbenchFeedback(); scheduleWorkbenchTranslation() }
            } catch { handle(error) }
        } else {
            guard comparisonIDs != ids else { return }
            liveTranslation.suspend(); clearWorkbenchFeedback()
            comparisonIDs = ids
            refreshComparison()
        }
    }

    private func refreshComparison(force: Bool = false) {
        let choices = workbenchServiceChoices.filter { comparisonIDs.contains($0.id) }
        if choices.count < 2 {
            if translatingOutsideWorkbench {
                comparisonIDs = []; comparisons.suspend(clearResults: true)
                return
            }
            useWorkbenchServices(choices.isEmpty ? [services.selectedID?.uuidString ?? "apple"] : choices.map(\.id))
            return
        }
        comparisonIDs = choices.map(\.id)
        comparisons.configure(choices, force: force)
        scheduleWorkbenchTranslation()
    }

    private func clearWorkbenchFeedback() {
        if feedback?.surface == .workbench { feedback = nil; busy = false; onFeedback?() }
        message = ""; isError = false; resultText = ""; resultLanguage = nil; workbenchContent = nil
    }

    private func receiveComparisonChange() {
        guard isComparing, !translatingOutsideWorkbench else { return }
        if comparisons.isTranslating {
            if feedback?.surface != .workbench { lastGlobalAction = nil; _ = begin(surface: .workbench) }
            busy = true
        } else if feedback?.surface == .workbench {
            busy = false; feedback = nil; message = ""; isError = false; onFeedback?()
        }
        resultLanguage = comparisons.results.compactMap(\.language).first
        resultText = comparisons.results.first(where: { $0.phase == .completed })?.text ?? ""
        workbenchContent = nil
    }

    func retryComparison(_ id: String) {
        guard isComparing, !translatingOutsideWorkbench, !preparing, !isComposing else { return }
        comparisons.retry(id, input: workbenchInput, isComposing: false)
    }

    func start() {
        hotKeys.onTrigger = { [weak self] action in self?.trigger(action) }
        installShortcuts()
        refreshPermission()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        Task { await refreshLanguagePack() }
    }

    func shutdown() {
        permissionTimer?.invalidate()
        liveTranslation.suspend()
        comparisons.suspend()
        operation?.cancel()
        provider.cancel()
        textAccess.restoreClipboard()
        hotKeys.shutdown()
    }

    func refreshPermission() {
        let granted = textAccess.isTrusted
        if accessibilityGranted != granted { accessibilityGranted = granted }
    }

    func translateManually() {
        guard hasWorkbenchServices, !translatingOutsideWorkbench, !preparing, !isComposing else { return }
        if isComparing { comparisons.update(workbenchInput, isComposing: isComposing, immediately: true) }
        else { liveTranslation.translateNow(workbenchInput, isComposing: isComposing) }
    }

    func workbenchTextChanged(_ text: String, isComposing: Bool) {
        guard !translatingOutsideWorkbench else { return }
        self.isComposing = isComposing
        if !isComposing { sourceText = text }
        scheduleWorkbenchTranslation()
    }

    func scheduleWorkbenchTranslation() {
        guard hasWorkbenchServices, !translatingOutsideWorkbench else { return }
        if isComparing { comparisons.update(workbenchInput, isComposing: isComposing || preparing) }
        else { liveTranslation.update(workbenchInput, isComposing: isComposing || preparing) }
    }

    func clearWorkbench() {
        guard !translatingOutsideWorkbench else { return }
        isComposing = false
        sourceText = ""
        contextBefore = ""; contextAfter = ""
        workbenchEditorRevision = UUID()
        scheduleWorkbenchTranslation()
    }

    private func receiveWorkbenchEvent(_ event: LiveTranslationController.Event) {
        switch event {
        case .cleared:
            if feedback?.surface == .workbench {
                busy = false
                committing = false
                feedback = nil
                onFeedback?()
            }
            resultText = ""
            resultLanguage = nil
            workbenchExecutionInfo = nil
            workbenchContent = nil
            message = ""
            isError = false
        case .started:
            lastGlobalAction = nil
            _ = begin(surface: .workbench)
        case let .target(language): resultLanguage = language
        case let .progress(progress):
            if feedback?.surface == .workbench { feedback?.progress = progress }
        case let .completed(text, language):
            resultText = text
            resultLanguage = language
            workbenchExecutionInfo = provider.executionInfo
            workbenchContent = TranslatedContent(text: text)
            finish(L10n.tr("翻译完成"))
            updateFeedback(.success, title: L10n.tr("翻译完成"))
        case let .failed(error): handle(error)
        case .cancelled:
            finish(L10n.tr("已取消"))
            updateFeedback(.cancelled, title: L10n.tr("已取消"))
        }
    }

    func trigger(_ action: ShortcutAction) {
        comparisons.suspend(clearResults: true)
        liveTranslation.suspend()
        if feedback?.surface == .workbench {
            busy = false
            feedback = nil
            onFeedback?()
        }
        guard !busy, !preparing else { return }
        lastGlobalAction = action
        guard textAccess.isTrusted else {
            message = TextAccessFailure.permission.localizedDescription
            isError = true
            feedback = TranslationFeedback(id: UUID(), phase: .failure, surface: .floating,
                title: L10n.tr("需要辅助功能权限"), detail: L10n.tr("开启后可读取文字并回填输入框。"), recovery: .settings,
                anchor: CGRect(origin: NSEvent.mouseLocation, size: .zero))
            onFeedback?()
            return
        }
        let fixedTarget = action == .input ? settings.inputTarget : settings.selectionTarget
        let direction = action == .input ? settings.inputDirection : settings.selectionDirection
        let preserveCode = settings.preserveCode
        let provider = self.provider
        let assistanceSettings = translationPreferences.settings
        let sceneSnapshot = translationProfiles.catalog.snapshot
        let id = begin(surface: .floating, phase: .reading)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await self.textAccess.capture(action, preserveCode: preserveCode, useContext: assistanceSettings.useContext)
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                self.feedback?.anchor = capture.feedbackAnchor ?? self.feedback?.anchor
                var request = try direction.request(text: capture.text, fixedTarget: fixedTarget, preserveCode: preserveCode)
                request.guidance = self.guidance(context: capture.context, settings: assistanceSettings, profile: sceneSnapshot, capturedProfile: true)
                let target = request.target
                self.selectionContextStatus = capture.contextStatus
                self.selectionExecutionInfo = nil
                if action == .selection {
                    self.selectionText = capture.text
                    self.selectionTitle = L10n.tr("翻译预览")
                    self.selectionResult = ""
                    self.selectionContent = nil
                    self.selectionError = ""
                    self.selectionApp = capture.application.localizedName ?? L10n.tr("当前应用")
                    self.selectionLanguage = target
                    self.selectionBusy = true
                    self.feedback?.surface = .selection
                    self.onShowSelection?()
                }
                self.updateFeedback(.translating, title: L10n.tr("正在翻译"), detail: target.name)
                let content = try await capture.format.translate(request, using: provider,
                    progress: self.progressHandler(for: id))
                let result = content.text
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                self.selectionExecutionInfo = provider.executionInfo
                if action == .selection {
                    self.selectionResult = result
                    self.selectionContent = content
                    if content.writebackRefusal != nil { self.selectionError = L10n.tr("未读取到原文样式，当前提供纯文本译文。") }
                    self.selectionBusy = false
                    self.finish(L10n.tr("选中文字已翻译"))
                    self.updateFeedback(.success, title: L10n.tr("翻译完成"))
                } else {
                    self.isComposing = false
                    self.workbenchEditorRevision = UUID()
                    self.sourceText = capture.text
                    self.contextBefore = capture.context.before
                    self.contextAfter = capture.context.after
                    self.resultText = result
                    self.workbenchContent = content
                    self.resultLanguage = target
                    self.workbenchExecutionInfo = provider.executionInfo
                    if result == capture.text {
                        self.finish(L10n.tr("内容无需替换，原文已保留。"))
                        self.updateFeedback(.info, title: L10n.tr("内容无需替换"))
                        return
                    }
                    do {
                        try await self.textAccess.replaceInput(capture, with: content) {
                            self.committing = true
                            self.updateFeedback(.replacing, title: L10n.tr("正在替换"))
                        }
                        guard self.operationID == id else { return }
                        self.finish(L10n.tr("\(capture.inputScope == .selection ? L10n.tr("选中部分") : L10n.tr("整个输入框"))已译为\(target.name)，可按 ⌘Z 撤销"))
                        self.updateFeedback(.success, title: L10n.tr("已替换"), detail: L10n.tr("⌘Z 撤销"))
                    } catch {
                        guard self.operationID == id else { return }
                        self.finish(error.localizedDescription, error: true)
                        self.selectionText = capture.text
                        self.selectionTitle = L10n.tr("译文已保留")
                        self.selectionResult = result
                        self.selectionContent = content
                        self.selectionLanguage = target
                        self.selectionApp = capture.application.localizedName ?? L10n.tr("当前应用")
                        self.selectionError = error.localizedDescription
                        self.selectionBusy = false
                        self.updateFeedback(.failure, title: L10n.tr("译文已保留"), detail: error.localizedDescription,
                            recovery: .preservedTranslation)
                    }
                }
            } catch {
                guard self.operationID == id else { return }
                self.selectionBusy = false
                if action == .selection { self.selectionError = error.localizedDescription }
                self.handle(error)
            }
        }
    }

    func cancel() {
        guard busy, !committing else { return }
        if feedback?.surface == .workbench {
            if isComparing { comparisons.suspend() } else { liveTranslation.cancel() }
            return
        }
        operationID = UUID()
        operation?.cancel()
        provider.cancel()
        operation = nil
        busy = false
        selectionBusy = false
        message = L10n.tr("已取消，原文已保留。")
        isError = false
        if selectionResult.isEmpty { selectionError = "" }
        updateFeedback(.cancelled, title: L10n.tr("已取消"), detail: L10n.tr("原文已保留"))
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(text, forType: .string)
        message = copied ? "" : L10n.tr("复制未完成，请重试。")
        isError = !copied
    }

    func copyWorkbenchResult() {
        copyResult(resultText, content: workbenchContent)
    }

    func copySelectionResult() {
        copyResult(selectionResult, content: selectionContent)
    }

    private func copyResult(_ text: String, content: TranslatedContent?) {
        guard let content, content.text == text else { copy(text); return }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.writeObjects([content.pasteboardItem()])
        message = copied ? "" : L10n.tr("复制未完成，请重试。")
        isError = !copied
    }

    func swapLanguages() {
        guard !translatingOutsideWorkbench, !isComposing else { return }
        liveTranslation.suspend()
        comparisons.suspend()
        if feedback?.surface == .workbench { busy = false }
        let previous = settings.inputTarget
        let detected = try? LanguageDetection.source(for: TranslationRequest(text: sourceText, source: sourceLanguage,
            target: previous, preserveCode: settings.preserveCode))
        settings.inputDirection = .fixedTarget
        settings.inputTarget = detected ?? .simplifiedChinese
        sourceLanguage = previous
        if !resultText.isEmpty {
            swap(&sourceText, &resultText)
            contextBefore = ""; contextAfter = ""
            workbenchContent = nil
            resultLanguage = settings.inputTarget
        }
        workbenchEditorRevision = UUID()
        scheduleWorkbenchTranslation()
    }

    func prepareLanguages() {
        guard !preparing, !busy, prepareSource != prepareTarget else { return }
        liveTranslation.suspend()
        comparisons.suspend()
        preparing = true
        preparationID = UUID()
        packStatus = L10n.tr("等待系统确认下载")
        var configuration = TranslationSession.Configuration(source: Locale.Language(identifier: prepareSource.rawValue), target: Locale.Language(identifier: prepareTarget.rawValue))
        if #available(macOS 26.4, *) { configuration.preferredStrategy = .lowLatency }
        preparationConfiguration = configuration
    }

    func completePreparation(_ session: TranslationSession) async {
        let id = preparationID
        let source = prepareSource
        let target = prepareTarget
        preparationSession = session
        do {
            try await session.prepareTranslation()
            guard id == preparationID else { return }
            let status = await AppleTranslationProvider.availability().status(from: Locale.Language(identifier: source.rawValue), to: Locale.Language(identifier: target.rawValue))
            guard id == preparationID else { return }
            message = status == .installed ? L10n.tr("语言包已安装") : L10n.tr("语言包尚未就绪")
            isError = false
        } catch {
            guard id == preparationID else { return }
            packStatus = L10n.tr("未完成准备：\(error.localizedDescription)")
            isError = true
            message = L10n.tr("语言包下载未完成")
        }
        preparing = false
        preparationSession = nil
        preparationConfiguration = nil
        scheduleWorkbenchTranslation()
        await refreshLanguagePack()
    }

    func cancelPreparation() {
        guard preparing else { return }
        preparationID = UUID()
        preparationSession?.cancel()
        preparationSession = nil
        preparationConfiguration = nil
        preparing = false
        packStatus = L10n.tr("已取消下载")
        scheduleWorkbenchTranslation()
    }

    func refreshLanguagePack() async {
        let revision = UUID()
        packRevision = revision
        let source = prepareSource
        let target = prepareTarget
        if source == target {
            packStatus = L10n.tr("请选择不同语言")
            packInstalled = false
            return
        }
        if source.isChinese && target.isChinese {
            packStatus = L10n.tr("无需语言包")
            packInstalled = true
            return
        }
        let available: Bool
        let statusText: String
        do {
            let (route, _) = try await AppleTranslationProvider.installedSessionRoute(source: source, target: target)
            available = true
            statusText = route.source == source && route.target == target ? L10n.tr("已安装") : L10n.tr("可用（复用已安装的中文语言包）")
        } catch TranslationFailure.systemNotReady {
            available = true
            statusText = L10n.tr("已安装，系统暂未就绪")
        } catch TranslationFailure.needsLanguagePack {
            available = false
            statusText = L10n.tr("未下载")
        } catch TranslationFailure.unsupportedLanguage {
            available = false
            statusText = L10n.tr("不支持这组语言")
        } catch is CancellationError { return }
        catch {
            available = false
            statusText = L10n.tr("暂时无法检查")
        }
        guard revision == packRevision else { return }
        packInstalled = available
        if !preparing { packStatus = statusText }
    }

    func beginShortcutEditing() {
        editingShortcut = true
        shortcutMessage = ""
        hotKeys.suspend()
    }

    func endShortcutEditing() {
        editingShortcut = false
        installShortcuts()
    }

    /// Validate and register before persisting; failed edits leave the saved bindings intact.
    func saveShortcut(_ shortcut: KeyboardShortcut, for action: ShortcutAction) -> String? {
        shortcutMessage = ""
        let other = action == .input ? settings.selectionShortcut : settings.inputShortcut
        if shortcut.keyCode == other.keyCode && shortcut.modifiers == other.modifiers {
            return L10n.tr("这个快捷键已经用于\(action == .input ? L10n.tr("选中文字翻译") : L10n.tr("输入框翻译"))，请换一个。")
        }
        let input = action == .input ? shortcut : settings.inputShortcut
        let selection = action == .selection ? shortcut : settings.selectionShortcut
        do {
            try applyShortcuts(input: input, selection: selection)
            if action == .input { settings.inputShortcut = shortcut } else { settings.selectionShortcut = shortcut }
            if editingShortcut { hotKeys.suspend() }
            return nil
        } catch {
            if editingShortcut { hotKeys.suspend() } else { installShortcuts() }
            return error.localizedDescription
        }
    }

    func restoreDefaultShortcuts() {
        do {
            try applyShortcuts(input: .inputDefault, selection: .selectionDefault)
            settings.inputShortcut = .inputDefault
            settings.selectionShortcut = .selectionDefault
            shortcutMessage = ""
            shortcutMessage = L10n.tr("快捷键已恢复默认")
        } catch {
            shortcutMessage = error.localizedDescription
            installShortcuts()
        }
    }

    private func applyShortcuts(input: KeyboardShortcut, selection: KeyboardShortcut) throws {
        hotKeys.suspend()
        do {
            try hotKeys.register(input, for: .input)
            try hotKeys.register(selection, for: .selection)
        } catch {
            hotKeys.suspend()
            throw error
        }
    }

    private func installShortcuts() {
        do {
            try applyShortcuts(input: settings.inputShortcut, selection: settings.selectionShortcut)
        } catch { shortcutMessage = error.localizedDescription }
    }

    private func begin(surface: FeedbackSurface, phase: FeedbackPhase = .translating) -> UUID {
        let id = UUID()
        operationID = id
        busy = true
        committing = false
        isError = false
        message = L10n.tr("正在翻译…")
        feedback = TranslationFeedback(id: id, phase: phase, surface: surface,
            title: phase == .reading ? L10n.tr("正在读取") : L10n.tr("正在翻译"),
            anchor: surface == .floating ? CGRect(origin: NSEvent.mouseLocation, size: .zero) : nil)
        onFeedback?()
        return id
    }

    private func finish(_ text: String, error: Bool = false) {
        busy = false
        committing = false
        message = text
        isError = error
        operation = nil
    }

    private func handle(_ error: Error) {
        if error is CancellationError {
            finish(L10n.tr("已取消，原文已保留。"))
            updateFeedback(.cancelled, title: L10n.tr("已取消"), detail: L10n.tr("原文已保留"))
            return
        }
        finish(error.localizedDescription, error: true)
        if case let TranslationFailure.needsLanguagePack(source, target) = error {
            prepareSource = source
            prepareTarget = target
            Task { await refreshLanguagePack() }
            updateFeedback(.failure, title: L10n.tr("需要下载语言包"), detail: "\(source.name) → \(target.name)", recovery: .languagePacks)
        } else if error is TextAccessFailure {
            updateFeedback(.failure, title: L10n.tr("暂时无法翻译"), detail: error.localizedDescription, recovery: .workbench)
        } else if case TranslationFailure.outsideBilingualPair = error {
            updateFeedback(.failure, title: L10n.tr("请更换翻译方向"), detail: error.localizedDescription, recovery: .settings)
        } else if case TranslationFailure.unsupportedLanguage = error {
            updateFeedback(.failure, title: L10n.tr("暂不支持这组语言"), detail: error.localizedDescription, recovery: .settings)
        } else {
            updateFeedback(.failure, title: L10n.tr("翻译未完成"), detail: error.localizedDescription, recovery: .retry)
        }
    }

    private func progressHandler(for id: UUID) -> TranslationProgressHandler {
        { [weak self] progress in
            guard let self, self.operationID == id, self.busy else { return }
            self.feedback?.progress = progress
        }
    }

    private func updateFeedback(_ phase: FeedbackPhase, title: String, detail: String = "", recovery: FeedbackRecovery? = nil) {
        guard phase.showsFeedback else {
            feedback = nil
            if !isError { message = "" }
            onFeedback?()
            return
        }
        guard var state = feedback else { return }
        state.phase = phase
        state.title = title
        state.detail = detail
        state.recovery = recovery
        feedback = state
        onFeedback?()
    }

    func dismissFeedback() {
        guard feedback?.phase.isActive != true else { return }
        feedback = nil
        onFeedback?()
    }

    func recoverFromFeedback() {
        guard let recovery = feedback?.recovery else { return }
        dismissFeedback()
        switch recovery {
        case .retry:
            if let action = lastGlobalAction { trigger(action) } else { translateManually() }
        case .settings: onShowSettings?()
        case .languagePacks: onShowLanguagePacks?()
        case .workbench: onShowWindow?()
        case .preservedTranslation: onShowSelection?()
        }
    }

    func showSettings() { onShowSettings?() }
    func showLanguagePacks() { onShowLanguagePacks?() }
    func showServices() { onShowServices?() }
    func showProfiles() { onShowProfiles?() }
}

@MainActor
private final class UnavailableTranslationProvider: TranslationProvider {
    let name = L10n.tr("服务配置不可用")
    let error: Error
    init(error: Error) { self.error = error }
    func translate(_ request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> String { throw error }
    func translateSegments(_ texts: [String], for request: TranslationRequest, progress: TranslationProgressHandler?) async throws -> [String] { throw error }
    func cancel() {}
}

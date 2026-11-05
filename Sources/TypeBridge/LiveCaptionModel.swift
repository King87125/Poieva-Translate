import AppKit
import Combine
import TypeBridgeCore

struct CaptionTranslationRecipe {
    let provider: any TranslationProvider
    let request: (String, String) throws -> TranslationRequest
}

@MainActor
final class CaptionSettings: ObservableObject {
    @Published var speechID: UUID? { didSet { save() } }
    @Published var translationID: String { didSet { save() } }
    @Published var source: AppLanguage { didSet { save() } }
    @Published var target: AppLanguage { didSet { save() } }
    @Published var audioBundleID: String { didSet { save() } }
    @Published var includeMicrophone: Bool { didSet { save() } }
    @Published var showOriginal: Bool { didSet { save() } }
    @Published var fontSize: Double { didSet { save() } }
    @Published var screenID: String { didSet { save() } }
    private let defaults: UserDefaults
    private struct Saved: Codable {
        var speechID: UUID?; var translationID: String; var source: AppLanguage; var target: AppLanguage
        var audioBundleID: String; var includeMicrophone: Bool; var showOriginal: Bool; var fontSize: Double; var screenID: String
    }
    init(defaults: UserDefaults, defaultTranslator: String) {
        self.defaults = defaults
        let old = defaults.data(forKey: "liveCaptionSettings.v1").flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        speechID = old?.speechID; translationID = old?.translationID ?? defaultTranslator
        source = old?.source ?? .automatic; target = old?.target ?? .simplifiedChinese
        audioBundleID = old?.audioBundleID ?? ""; includeMicrophone = old?.includeMicrophone ?? false
        showOriginal = old?.showOriginal ?? true; fontSize = min(30, max(18, old?.fontSize ?? 23)); screenID = old?.screenID ?? ""
    }
    private func save() {
        let value = Saved(speechID: speechID, translationID: translationID, source: source, target: target,
            audioBundleID: audioBundleID, includeMicrophone: includeMicrophone, showOriginal: showOriginal, fontSize: fontSize, screenID: screenID)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "liveCaptionSettings.v1") }
    }
}

@MainActor
final class LiveCaptionModel: ObservableObject {
    enum Phase { case idle, connecting, listening, paused, failed, preview }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var error = ""
    @Published var expanded = true
    @Published var islandVisible = false
    let settings: CaptionSettings
    let transcript = CaptionTranslationController()
    let speechServices: SpeechServiceStore
    var onShowIsland: (() -> Void)?
    var onShowSettings: (() -> Void)?
    private let recipe: (String, AppLanguage, AppLanguage) -> CaptionTranslationRecipe
    private var startTask: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var sockets: [RealtimeTranscriber] = []
    private var captures: [CaptionAudioCapture] = []
    private var revision = UUID()
    private var demoTask: Task<Void, Never>?
    private var sampleURL: URL?
    private var scopedSample = false
    private var sourceBundleID = ""
    private var sampleEnded = false
    private var sampleCommits = 0
    private var sampleRequiresFinish = false
    private var sampleRecognitionFinished = false
    private var sampleCompletions: Set<String> = []
    private var notificationTokens: [NSObjectProtocol] = []
    var isActive: Bool { phase == .connecting || phase == .listening }
    var status: String {
        switch phase {
        case .idle: return L10n.tr("实时字幕")
        case .connecting: return L10n.tr("正在连接识别服务…")
        case .listening: return sampleURL == nil ? L10n.tr("正在听取") : L10n.tr("音频文件测试")
        case .paused: return L10n.tr("字幕已暂停")
        case .failed: return L10n.tr("字幕已暂停")
        case .preview: return L10n.tr("样例预览")
        }
    }
    init(settings: CaptionSettings, speechServices: SpeechServiceStore,
         recipe: @escaping (String, AppLanguage, AppLanguage) -> CaptionTranslationRecipe) {
        self.settings = settings; self.speechServices = speechServices; self.recipe = recipe
        transcript.onFailure = { [weak self] error in self?.fail(error) }
        transcript.onIdle = { [weak self] in self?.finishSampleIfReady() }
        speechServices.onChange = { [weak self] id in
            guard let self else { return }
            if self.settings.speechID == id { self.configurationChanged() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            })
        }
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, self.isActive, !self.sourceBundleID.isEmpty, self.sourceBundleID == bundleID else { return }
                self.fail(CaptionFailure.sourceGone)
            }
        })
    }
    func start(file: URL? = nil) {
        guard !isActive else { return }
        stopResources(); transcript.stop(clear: true); error = ""
        let id = UUID(); revision = id; phase = .connecting; expanded = true; islandVisible = true; onShowIsland?()
        let chosenID = settings.speechID, bundleID = settings.audioBundleID, microphone = settings.includeMicrophone && file == nil
        let translator = recipe(settings.translationID, settings.source, settings.target)
        sourceBundleID = file == nil ? bundleID : ""
        sampleURL = file; scopedSample = file?.startAccessingSecurityScopedResource() ?? false
        sampleEnded = false; sampleCommits = 0; sampleCompletions = []; sampleRecognitionFinished = false; sampleRequiresFinish = false
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if file == nil, !bundleID.isEmpty,
                   !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) { throw CaptionFailure.sourceGone }
                guard let configuration = self.speechServices.configurations.first(where: { $0.id == chosenID }) else { throw CaptionFailure.noService }
                self.sampleRequiresFinish = configuration.kind.usesServerVAD
                let key = try self.speechServices.key(for: configuration.id)
                self.transcript.start(provider: translator.provider, request: translator.request)
                let system = try await self.connect(configuration, key: key, channel: "system", revision: id)
                let mic = microphone ? try await self.connect(configuration, key: key, channel: "mic", revision: id) : nil
                try Task.checkCancellation(); guard self.revision == id else { return }
                if let file {
                    self.consume(try CaptionAudioCapture.replay(file, sampleRate: system.sampleRate), socket: system, revision: id)
                } else {
                    // Each input has its own clock and recognition session; no
                    // mixing/double counting of the microphone and meeting audio.
                    let capture = CaptionAudioCapture(); self.captures.append(capture)
                    if let mic {
                        let microphoneCapture = CaptionAudioCapture(); self.captures.append(microphoneCapture)
                        let frames = try await microphoneCapture.startMicrophone(sampleRate: mic.sampleRate)
                        try Task.checkCancellation(); guard self.revision == id else { return }
                        self.consume(frames, socket: mic, revision: id)
                    }
                    self.consume(try capture.startSystem(bundleID: bundleID.isEmpty ? nil : bundleID, sampleRate: system.sampleRate), socket: system, revision: id)
                }
                self.phase = .listening; self.startTask = nil
            } catch {
                guard self.revision == id, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }
    private func connect(_ configuration: SpeechServiceConfiguration, key: String?, channel: String, revision id: UUID) async throws -> RealtimeTranscriber {
        let socket = RealtimeTranscriber(); sockets.append(socket)
        try await socket.connect(configuration: configuration, key: key)
        try Task.checkCancellation(); guard revision == id else { throw CancellationError() }
        tasks.append(Task { @MainActor [weak self] in
            do {
                for try await event in socket.events {
                    guard let self, self.revision == id, !Task.isCancelled else { return }
                    if event == .finished {
                        guard self.sampleURL != nil, self.sampleRequiresFinish else { throw CaptionFailure.connection }
                        self.sampleRecognitionFinished = true; self.finishSampleIfReady(); continue
                    }
                    let prefix = channel + ":"
                    let value: CaptionTranscriptEvent
                    switch event {
                    case .committed(let item, let previous): value = .committed(id: prefix + item, previous: previous.map { prefix + $0 })
                    case .delta(let item, let text): value = .delta(id: prefix + item, text: text)
                    case .snapshot(let item, let text): value = .snapshot(id: prefix + item, text: text)
                    case .completed(let item, let text): value = .completed(id: prefix + item, text: text)
                    case .finished: continue
                    }
                    try self.transcript.receive(value, channel: channel == "mic" ? L10n.tr("我") : L10n.tr("原声"))
                    if self.sampleURL != nil, !self.sampleRequiresFinish, case .completed(let item, _) = value, self.sampleCompletions.insert(item).inserted {
                        self.sampleCommits = max(0, self.sampleCommits - 1); self.finishSampleIfReady()
                    }
                }
            } catch { if let self, self.revision == id, !Task.isCancelled { self.fail(error) } }
        })
        return socket
    }
    private func consume(_ stream: AsyncThrowingStream<CaptionAudioFrame, Error>, socket: RealtimeTranscriber, revision id: UUID) {
        tasks.append(Task { @MainActor [weak self] in
            var gate = CaptionAudioGate()
            do {
                for try await frame in stream {
                    guard let self, self.revision == id, !Task.isCancelled else { return }
                    guard frame.sampleRate == socket.sampleRate else { throw CaptionFailure.audioFormat }
                    // Qwen's server VAD needs the silence as well as speech;
                    // sending local manual commits would end its turns twice.
                    for action in socket.usesServerVAD ? [.append(frame.pcm)] : gate.consume(frame) {
                        if self.sampleURL != nil, action == .commit { self.sampleCommits += 1 }
                        try await socket.send(action)
                    }
                }
                if let self, self.revision == id, self.sampleURL != nil {
                    self.sampleEnded = true
                    if socket.usesServerVAD { try await socket.finishInput() }
                    self.finishSampleIfReady()
                    if self.sampleURL != nil {
                        self.tasks.append(Task { @MainActor [weak self] in
                            do {
                                try await Task.sleep(for: .seconds(20))
                                if let self, self.revision == id, self.sampleURL != nil { self.fail(CaptionFailure.timeout) }
                            } catch {}
                        })
                    }
                }
            } catch { if let self, self.revision == id, !Task.isCancelled { self.fail(error) } }
        })
    }
    private func finishSampleIfReady() {
        guard sampleURL != nil, sampleEnded, (sampleRequiresFinish ? sampleRecognitionFinished : sampleCommits == 0),
              transcript.lines.allSatisfy({ $0.isFinal && ($0.source.isEmpty || !$0.translation.isEmpty) }) else { return }
        pause()
    }
    func pause() {
        guard isActive || phase == .preview else { return }
        stopResources(); transcript.stop(); phase = .paused
    }
    func stop() {
        stopResources(); transcript.stop(clear: true); phase = .idle; error = ""; islandVisible = false
    }
    func configurationChanged() {
        if isActive { pause(); error = L10n.tr("配置已修改，请重新开始字幕。") }
    }
    private func fail(_ error: Error) {
        stopResources(); transcript.stop(); self.error = error.localizedDescription; phase = .failed; expanded = true
        islandVisible = true; onShowIsland?()
    }
    private func stopResources() {
        revision = UUID(); startTask?.cancel(); startTask = nil; demoTask?.cancel(); demoTask = nil
        for capture in captures { capture.stop() }; captures = []
        for socket in sockets { socket.cancel() }; sockets = []
        for task in tasks { task.cancel() }; tasks = []
        if scopedSample { sampleURL?.stopAccessingSecurityScopedResource() }
        sampleURL = nil; scopedSample = false
    }
    func preview() {
        guard !isActive else { return }
        stopResources(); phase = .preview; error = ""; expanded = true; islandVisible = true
        transcript.showSample([.init(id: "preview-1", source: "Let's keep the discussion focused.", translation: L10n.tr("我们围绕重点来讨论。"), isFinal: true)])
        onShowIsland?()
        demoTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.transcript.showSample([
                    .init(id: "preview-1", source: "Let's keep the discussion focused.", translation: L10n.tr("我们围绕重点来讨论。"), isFinal: true),
                    .init(id: "preview-2", source: "We can review the next steps together.", translation: L10n.tr("接下来，我们一起确认后续安排。"), isFinal: true)
                ])
            } catch {}
        }
    }
}

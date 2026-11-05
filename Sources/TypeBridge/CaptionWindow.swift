import AppKit
import Combine
import SwiftUI
import TypeBridgeCore

@MainActor
final class CaptionWindowController: NSObject, NSWindowDelegate {
    private let model: LiveCaptionModel
    private let panel: NSWindow
    private var subscriptions: Set<AnyCancellable> = []
    private var screenToken: NSObjectProtocol?
    private var positioned = false
    private var screenID: String
    var window: NSWindow { panel }

    init(model: LiveCaptionModel) {
        self.model = model
        screenID = model.settings.screenID
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        panel.title = L10n.tr("字幕窗口")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 400, height: 220)
        panel.delegate = self
        positioned = panel.setFrameUsingName("Poieva.CaptionWindow.v1")
        panel.setFrameAutosaveName("Poieva.CaptionWindow.v1")
        let restoredFrame = panel.frame
        let host = NSHostingController(rootView: CaptionWindowView(model: model, transcript: model.transcript, settings: model.settings))
        host.sizingOptions = []
        panel.contentViewController = host
        // Installing an unconstrained hosting view can shrink the window to its
        // minimum size. Apply the saved or default geometry after installation.
        if positioned { panel.setFrame(restoredFrame, display: false) }
        else { panel.setContentSize(NSSize(width: 660, height: 420)) }
        Publishers.MergeMany(model.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            model.settings.objectWillChange.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update(ensureOnScreen: true) }
        }
    }

    func show() {
        update()
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
    }

    private func update(ensureOnScreen: Bool = false) {
        guard model.captionVisible else { panel.orderOut(nil); return }
        let chosen = NSScreen.screens.first { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == model.settings.screenID }
        guard let screen = chosen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let movedDisplay = screenID != model.settings.screenID
        if !positioned || movedDisplay {
            let bounds = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            let size = NSSize(width: min(panel.frame.width, bounds.width), height: min(panel.frame.height, bounds.height))
            panel.setFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.minY + min(64, max(0, bounds.height - size.height)), width: size.width, height: size.height), display: true)
            positioned = true
        } else if ensureOnScreen || !NSScreen.screens.contains(where: { $0.visibleFrame.intersection(panel.frame).width >= 160 && $0.visibleFrame.intersection(panel.frame).height >= 80 }) {
            let bounds = screen.visibleFrame
            var frame = panel.frame
            frame.size.width = min(frame.width, bounds.width)
            frame.size.height = min(frame.height, bounds.height)
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
            panel.setFrame(frame, display: true)
        }
        screenID = model.settings.screenID
        if !panel.isVisible && !panel.isMiniaturized { panel.orderFrontRegardless() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.stop()
        panel.orderOut(nil)
        return false
    }
}

@MainActor
private struct CaptionWindowView: View {
    @ObservedObject var model: LiveCaptionModel
    @ObservedObject var transcript: CaptionTranslationController
    @ObservedObject var settings: CaptionSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var following = true
    @State private var userScrolling = false
    @State private var atBottom = true
    private let bottomID = "caption-bottom"
    private var rows: [CaptionLine] { transcript.lines.filter { !$0.source.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(model.phase == .failed ? Color.orange : (model.isActive ? .green : .gray)).frame(width: 6, height: 6)
                Text(model.status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 8)
                if model.isActive || model.phase == .preview {
                    icon("pause.fill", L10n.tr("暂停")) { model.pause() }
                }
                icon("slider.horizontal.3", L10n.tr("字幕设置")) { model.onShowSettings?() }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider().overlay(.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text(L10n.tr("等待声音…")).font(.system(size: settings.fontSize)).foregroundStyle(.white.opacity(0.65))
                                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                        }
                        ForEach(rows) { line in
                            VStack(alignment: .leading, spacing: 6) {
                                if settings.audioInput == .both, !line.channel.isEmpty {
                                    Text(line.channel).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                                }
                                if settings.showOriginal, !line.translation.isEmpty {
                                    Text(line.source).font(.system(size: max(13, settings.fontSize - 5))).foregroundStyle(.white.opacity(0.72))
                                }
                                Text(line.translation.isEmpty ? line.source : line.translation)
                                    .font(.system(size: settings.fontSize, weight: .medium))
                                    .foregroundStyle(.white.opacity(line.translation.isEmpty ? 0.8 : 1))
                            }
                            .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 15)
                            .id(line.id)
                            if line.id != rows.last?.id { Divider().overlay(.white.opacity(0.08)) }
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }.padding(.horizontal, 20).padding(.vertical, 3)
                }
                .accessibilityLabel(L10n.tr("字幕记录"))
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    if userScrolling { following = atBottom }
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 36
                } action: { _, value in
                    atBottom = value
                    if userScrolling { following = value }
                }
                .onChange(of: transcript.lines) { _, _ in
                    if following { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    if !following {
                        Button { following = true; proxy.scrollTo(bottomID, anchor: .bottom) } label: {
                            Label(L10n.tr("返回最新字幕"), systemImage: "arrow.down.to.line")
                        }.buttonStyle(.bordered).controlSize(.small).padding(.trailing, 16).padding(.bottom, 10)
                    }
                }
            }
            if !model.error.isEmpty {
                Divider().overlay(.white.opacity(0.08))
                Text(model.error).font(.system(size: 12)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Color(white: 0.16).opacity(reduceTransparency ? 1 : settings.backgroundOpacity).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
    }

    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 12)).frame(width: 24, height: 24) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).help(label).accessibilityLabel(label)
    }
}

import AppKit
import Combine
import SwiftUI
import TypeBridgeCore

private final class CaptionIslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptionIslandController {
    private let model: LiveCaptionModel
    private let panel: NSPanel
    private var subscriptions: Set<AnyCancellable> = []
    private var screenToken: NSObjectProtocol?
    init(model: LiveCaptionModel) {
        self.model = model
        panel = CaptionIslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.tr("实时字幕提词器")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        Publishers.MergeMany(model.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            model.settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(), model.transcript.objectWillChange.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
    func show() { update() }
    private func update() {
        guard model.islandVisible else { panel.orderOut(nil); return }
        let chosen = NSScreen.screens.first { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == model.settings.screenID }
        guard let screen = chosen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let notch = screen.safeAreaInsets.top
        let width = model.expanded ? min(680, screen.frame.width - 48) : 232
        let rows = Array(model.transcript.lines.filter { !$0.source.isEmpty }.suffix(2))
        let font = NSFont.systemFont(ofSize: model.settings.fontSize, weight: .medium)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var bodyHeight: CGFloat = 50 // header and vertical insets
        for row in rows {
            let text = row.translation.isEmpty ? row.source : row.translation
            let measured = (String(text.prefix(512)) as NSString).boundingRect(
                with: NSSize(width: width - 44, height: lineHeight * 2),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            bodyHeight += 12 + max(lineHeight, min(lineHeight * 2, ceil(measured.height)))
            if model.settings.showOriginal && !row.translation.isEmpty { bodyHeight += 20 }
        }
        if rows.isEmpty && model.error.isEmpty { bodyHeight += lineHeight + 12 }
        if !model.error.isEmpty { bodyHeight += 44 }
        bodyHeight = model.expanded ? max(86, bodyHeight) : 34
        let height = bodyHeight + notch
        let top = notch > 0 ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let rect = NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
        if panel.contentViewController == nil {
            let host = NSHostingController(rootView: CaptionIslandView(model: model, transcript: model.transcript, settings: model.settings, notchHeight: notch))
            host.sizingOptions = []; panel.contentViewController = host
        } else if panel.frame.width != rect.width || panel.frame.height != rect.height {
            (panel.contentViewController as? NSHostingController<CaptionIslandView>)?.rootView = CaptionIslandView(model: model, transcript: model.transcript, settings: model.settings, notchHeight: notch)
        }
        if panel.frame != rect { panel.setFrame(rect, display: true, animate: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

@MainActor
private struct CaptionIslandView: View {
    @ObservedObject var model: LiveCaptionModel
    @ObservedObject var transcript: CaptionTranslationController
    @ObservedObject var settings: CaptionSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let notchHeight: CGFloat
    private var lines: [CaptionLine] { Array(transcript.lines.filter { !$0.source.isEmpty }.suffix(2)) }
    var body: some View {
        VStack(spacing: 0) {
            if notchHeight > 0 { Color.black.frame(width: 185, height: notchHeight).allowsHitTesting(false) }
            VStack(alignment: .leading, spacing: model.expanded ? 12 : 0) {
                HStack(spacing: 8) {
                    Circle().fill(model.phase == .failed ? Color.orange : (model.isActive ? Color.green : Color.gray)).frame(width: 6, height: 6)
                    Text(model.status).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Spacer(minLength: 8)
                    if model.expanded {
                        HStack(spacing: 3) {
                            if model.isActive { icon("pause.fill", L10n.tr("暂停")) { model.pause() } }
                            else { Color.clear.frame(width: 22, height: 18) }
                            icon("slider.horizontal.3", L10n.tr("字幕设置")) { model.onShowSettings?() }
                            icon("xmark", L10n.tr("停止字幕")) { model.stop() }
                        }.opacity(hovering ? 1 : 0).allowsHitTesting(hovering).accessibilityHidden(!hovering)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                    }
                    // The collapse button never moves when hover controls appear.
                    Button { model.expanded.toggle() } label: { Image(systemName: model.expanded ? "chevron.up" : "chevron.down").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).frame(width: 22, height: 18) }
                        .buttonStyle(.plain).help(L10n.tr("展开或收起字幕")).accessibilityLabel(L10n.tr("展开或收起字幕"))
                }.frame(height: 18)
                if model.expanded {
                    if lines.isEmpty && model.error.isEmpty {
                        Text(model.phase == .preview ? L10n.tr("样例预览") : L10n.tr("等待声音…"))
                            .font(.system(size: settings.fontSize, weight: .medium)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 5) {
                            if settings.showOriginal, !line.translation.isEmpty { Text(line.source).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                            Text(line.translation.isEmpty ? line.source : line.translation)
                                .font(.system(size: settings.fontSize, weight: .medium)).foregroundStyle(.white.opacity(line.translation.isEmpty ? 0.65 : 1))
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).id(line.id + line.translation)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    if !model.error.isEmpty { Text(model.error).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2) }
                }
            }.padding(.horizontal, model.expanded ? 22 : 14).padding(.vertical, model.expanded ? 16 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: model.expanded ? 22 : 17))
                .overlay { RoundedRectangle(cornerRadius: model.expanded ? 22 : 17).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: lines)
        .contextMenu {
            Button(L10n.tr("字幕设置")) { model.onShowSettings?() }
            if model.isActive { Button(L10n.tr("暂停")) { model.pause() } }
            Button(L10n.tr("停止字幕")) { model.stop() }
        }
    }
    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).frame(width: 22, height: 18) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

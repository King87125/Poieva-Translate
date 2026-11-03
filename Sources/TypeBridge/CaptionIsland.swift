import AppKit
import Combine
import SwiftUI
import TypeBridgeCore

private final class CaptionIslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // The default constraint moves a window below the menu bar. This panel is
    // deliberately attached to the physical display edge, including the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class CaptionIslandController {
    private let model: LiveCaptionModel
    private let panel: NSPanel
    private var subscriptions: Set<AnyCancellable> = []
    private var screenToken: NSObjectProtocol?
    private var notchSize = NSSize.zero
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
        let notchHeight = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        let cameraWidth = notchHeight > 0 ? max(0, (right?.minX ?? screen.frame.midX) - (left?.maxX ?? screen.frame.midX)) : 0
        let camera = NSSize(width: cameraWidth, height: notchHeight)
        let centerX = cameraWidth > 0 ? ((left?.maxX ?? screen.frame.midX) + (right?.minX ?? screen.frame.midX)) / 2 : screen.frame.midX
        let width = model.expanded ? min(560, screen.frame.width - 32) : (cameraWidth > 0 ? cameraWidth + 80 : 232)
        let current = model.transcript.lines.last { !$0.source.isEmpty }
        let font = NSFont.systemFont(ofSize: model.settings.fontSize, weight: .medium)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var bodyHeight: CGFloat = 50 // header, spacing and vertical insets
        if let row = current {
            let text = row.translation.isEmpty ? row.source : row.translation
            let measured = (String(text.prefix(512)) as NSString).boundingRect(
                with: NSSize(width: width - 60, height: lineHeight * 2),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            bodyHeight += max(lineHeight, min(lineHeight * 2, ceil(measured.height)))
            if model.settings.showOriginal && !row.translation.isEmpty { bodyHeight += 19 }
        }
        if current == nil && model.error.isEmpty { bodyHeight += lineHeight }
        if !model.error.isEmpty { bodyHeight += 40 }
        let height = model.expanded ? notchHeight + max(80, bodyHeight) : (notchHeight > 0 ? notchHeight + 8 : 34)
        let top = notchHeight > 0 ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let rect = NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
        if panel.contentViewController == nil {
            let host = NSHostingController(rootView: CaptionIslandView(model: model, transcript: model.transcript, settings: model.settings, notchSize: camera))
            // Insets are already included above; SwiftUI must not insert the
            // screen's safe area a second time and detach the surface from it.
            host.sizingOptions = []; host.safeAreaRegions = []; panel.contentViewController = host
        } else if notchSize != camera {
            (panel.contentViewController as? NSHostingController<CaptionIslandView>)?.rootView = CaptionIslandView(model: model, transcript: model.transcript, settings: model.settings, notchSize: camera)
        }
        notchSize = camera
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
    let notchSize: NSSize
    private var current: CaptionLine? { transcript.lines.last { !$0.source.isEmpty } }
    var body: some View {
        Group {
            if !model.expanded && notchSize.height > 0 {
                Button { model.expanded = true } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "captions.bubble.fill").font(.system(size: 13)).foregroundStyle(statusColor)
                        Spacer(minLength: 0)
                        Color.clear.frame(width: notchSize.width)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).frame(width: 22)
                    }.padding(.horizontal, 18).frame(height: notchSize.height).padding(.bottom, 8)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.tr("展开或收起字幕")).accessibilityLabel(L10n.tr("展开或收起字幕"))
            } else {
            VStack(alignment: .leading, spacing: model.expanded ? 10 : 0) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
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
                    if current == nil && model.error.isEmpty {
                        Text(model.phase == .preview ? L10n.tr("样例预览") : L10n.tr("等待声音…"))
                            .font(.system(size: settings.fontSize, weight: .medium)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .center)
                    }
                    if let line = current {
                        VStack(alignment: .leading, spacing: 5) {
                            if settings.showOriginal, !line.translation.isEmpty { Text(line.source).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                            Text(line.translation.isEmpty ? line.source : line.translation)
                                .font(.system(size: settings.fontSize, weight: .medium)).foregroundStyle(.white.opacity(line.translation.isEmpty ? 0.65 : 1))
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).id(line.id + line.translation)
                                .transition(.opacity)
                        }
                    }
                    if !model.error.isEmpty { Text(model.error).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2) }
                }
            }.padding(.horizontal, model.expanded ? 30 : 14)
                .padding(.top, model.expanded ? notchSize.height + 8 : 8)
                .padding(.bottom, model.expanded ? 14 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { CaptionIslandSurface(attached: notchSize.height > 0).fill(.black) }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: current)
        .contextMenu {
            Button(L10n.tr("字幕设置")) { model.onShowSettings?() }
            if model.isActive { Button(L10n.tr("暂停")) { model.pause() } }
            Button(L10n.tr("停止字幕")) { model.stop() }
        }
    }
    private var statusColor: Color { model.phase == .failed ? .orange : (model.isActive ? .green : .gray) }
    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).frame(width: 22, height: 18) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// A continuous surface that grows out of the display edge. There is no
/// separate painted "camera" rectangle: the real camera housing stays inside it.
private struct CaptionIslandSurface: Shape {
    let attached: Bool
    func path(in rect: CGRect) -> Path {
        guard attached else { return Path(roundedRect: rect, cornerRadius: 17) }
        let shoulder: CGFloat = 12, radius = min(22, rect.height / 2)
        var path = Path()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: shoulder, y: shoulder), control: CGPoint(x: shoulder, y: 0))
        path.addLine(to: CGPoint(x: shoulder, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: shoulder + radius, y: rect.height), control: CGPoint(x: shoulder, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - shoulder - radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: rect.width - shoulder, y: rect.height - radius), control: CGPoint(x: rect.width - shoulder, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - shoulder, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: 0), control: CGPoint(x: rect.width - shoulder, y: 0))
        path.closeSubpath()
        return path
    }
}

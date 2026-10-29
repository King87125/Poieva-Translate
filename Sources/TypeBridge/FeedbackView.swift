import SwiftUI
import TypeBridgeCore

@MainActor
struct FeedbackView: View {
    let state: TranslationFeedback
    let style: FeedbackStyle
    var cancel: (() -> Void)?
    var dismiss: (() -> Void)?
    var recover: (() -> Void)?
    var compact = false
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if state.phase == .failure {
            failureBody
        } else if state.phase.isActive {
            if compact {
                loadingContent
                    .font(.system(size: 11))
                    .accessibilityElement(children: .ignore).accessibilityLabel(state.title)
            } else {
                loadingContent
                    .font(.system(size: 11))
                    .frame(width: loadingWidth, height: 28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.05), lineWidth: 0.5) }
                    .accessibilityElement(children: .ignore).accessibilityLabel(state.title)
                    .help(state.title)
            }
        }
    }

    private var loadingWidth: CGFloat {
        switch style {
        case .waves, .spinner: return 44
        case .typewriter: return L10n.language == .english ? 104 : 64
        case .characterCount: return 156
        }
    }

    @ViewBuilder private var loadingContent: some View {
        switch style {
        case .waves:
            if reduceMotion || !animates { waveDots(time: 0) }
            else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    waveDots(time: context.date.timeIntervalSince(state.startedAt))
                }
            }
        case .spinner:
            if reduceMotion || !animates {
                Image(systemName: "ellipsis").foregroundStyle(.tint)
            } else {
                ProgressView().controlSize(.mini).frame(width: 16, height: 16)
            }
        case .typewriter:
            if reduceMotion || !animates { Text(L10n.tr("翻译中")).foregroundStyle(.secondary) }
            else {
                TimelineView(.animation(minimumInterval: 0.12)) { context in
                    let t = context.date.timeIntervalSince(state.startedAt).truncatingRemainder(dividingBy: 3.4)
                    let label = L10n.tr("翻译中")
                    let count = min(label.count, max(1, Int(t / 0.1)))
                    HStack(spacing: 2) {
                        Text(String(label.prefix(count)))
                        Rectangle().frame(width: 1, height: 11).opacity(Int(t * 2) % 2 == 0 ? 0.7 : 0)
                    }.foregroundStyle(.secondary).frame(width: L10n.language == .english ? 82 : 42, alignment: .leading)
                }
            }
        case .characterCount:
            if let progress = state.progress, progress.totalCharacters > 0, state.phase == .translating {
                HStack(spacing: 4) {
                    if state.isPreview { Text(L10n.tr("预览")).foregroundStyle(.secondary) }
                    Text("\(progress.completedCharacters)").contentTransition(.numericText())
                    Text(L10n.tr("/ \(progress.totalCharacters) 字")).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .animation(reduceMotion || !animates ? nil : .easeOut(duration: 0.18), value: state.progress)
            } else {
                Text(state.title).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func waveDots(time: TimeInterval) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                let wave = reduceMotion || !animates ? 0 : sin(time * 5 - Double(index) * 0.85)
                Circle().fill(Color.accentColor.opacity(0.55 + (wave + 1) * 0.22))
                    .frame(width: 5, height: 5).offset(y: -wave * 3)
            }
        }.frame(width: 28, height: 16)
    }

    private var failureBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(state.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .frame(width: 18, height: 20).accessibilityLabel(L10n.tr("关闭提示"))
                }
            }.font(.system(size: 12))
            if !state.detail.isEmpty {
                Text(state.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).help(state.detail)
            }
            if let recovery = state.recovery {
                Button(recovery.title) { recover?() }
                    .buttonStyle(.link).font(.system(size: 11))
                    .disabled(recover == nil)
            }
        }
        .padding(10).frame(width: 248, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
        .accessibilityElement(children: .contain).accessibilityLabel(state.title)
    }
}

@MainActor
struct InlineFeedbackView: View {
    let state: TranslationFeedback
    let style: FeedbackStyle
    var animates = true
    var body: some View { FeedbackView(state: state, style: style, compact: true, animates: animates) }
}

@MainActor
struct FeedbackPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var body: some View {
        if let state = model.feedback, state.surface == .floating, state.phase.showsFeedback {
            FeedbackView(state: state, style: settings.feedbackStyle,
                dismiss: { model.dismissFeedback() }, recover: { model.recoverFromFeedback() })
        }
    }
}

@MainActor
struct FeedbackSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let animates: Bool
    @State private var phase = PreviewPhase.processing
    @State private var previewID = UUID()

    private enum PreviewPhase: String, CaseIterable, Identifiable {
        case processing, failure
        var id: String { rawValue }
        var title: String { self == .processing ? L10n.tr("加载") : L10n.tr("失败") }
    }

    private var preview: TranslationFeedback {
        TranslationFeedback(id: previewID, phase: phase == .processing ? .translating : .failure, surface: .floating,
            title: phase == .processing ? L10n.tr("正在翻译") : L10n.tr("译文已保留"),
            detail: phase == .processing ? "" : L10n.tr("光标或选区已改变，未自动替换。"),
            progress: TranslationProgress(completedCharacters: 128, totalCharacters: 256),
            recovery: phase == .failure ? .preservedTranslation : nil, isPreview: true)
    }

    var body: some View {
        HStack {
            Text(L10n.tr("动画效果"))
            Spacer()
            SelectionField(title: L10n.tr("动画效果"), selection: $settings.feedbackStyle,
                options: FeedbackStyle.allCases.map { SelectionOption($0, $0.name) }).frame(width: 180)
        }.accessibilityElement(children: .contain)
        VStack(spacing: 10) {
            HStack {
                Text(L10n.tr("预览")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(L10n.tr("预览状态"), selection: $phase) {
                    ForEach(PreviewPhase.allCases) { phase in Text(phase.title).tag(phase) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 140)
                Button(L10n.tr("播放浮窗")) { model.onPreviewFeedback?(preview) }.disabled(model.busy)
            }
            FeedbackView(state: preview, style: settings.feedbackStyle, animates: animates)
                .id(previewID).padding(.vertical, 6)
        }
        .padding(.vertical, 4)
        .onChange(of: settings.feedbackStyle) { _, _ in previewID = UUID() }
        .onChange(of: phase) { _, _ in previewID = UUID() }
    }
}

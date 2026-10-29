import AppKit
import SwiftUI
import TypeBridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    private lazy var model = AppModel()
    private var didStart = false
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var selectionPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var languagePackWindow: NSWindow?
    private var guideWindow: NSWindow?
    private var serviceWindow: NSWindow?
    private var feedbackPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var dismissPreview: DispatchWorkItem?
    private let settingsItemID = NSToolbarItem.Identifier("TypeBridge.Settings")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppBrand.installApplicationIcon()
        guard InterfaceLanguageSetup.prepare() else { NSApp.terminate(nil); return }
        didStart = true
        installMainMenu()
        createWindow()
        createStatusItem()
        model.onShowWindow = { [weak self] in self?.showWindow() }
        model.onShowSelection = { [weak self] in self?.showSelection() }
        model.onShowSettings = { [weak self] in self?.showSettings() }
        model.onShowLanguagePacks = { [weak self] in self?.showLanguagePacks() }
        model.onShowServices = { [weak self] in self?.showServices() }
        model.onFeedback = { [weak self] in self?.showFeedback() }
        model.onPreviewFeedback = { [weak self] state in self?.showFeedbackPreview(state) }
        model.start()
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) { if didStart { model.shutdown() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if didStart { showWindow() }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        if sender === window { model.workbenchVisible = false }
        if sender === settingsWindow { model.settingsVisible = false }
        if sender === selectionPanel { model.selectionVisible = false }
        if sender === languagePackWindow { model.cancelPreparation() }
        if ![window, settingsWindow, languagePackWindow, guideWindow, serviceWindow].compactMap({ $0 }).contains(where: \.isVisible) {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }

    private func createWindow() {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 760, height: 476)
        let preferredWidth: CGFloat = L10n.language == .english ? 880 : 760
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(preferredWidth, visible.width), height: min(432, visible.height - 60)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = AppBrand.name
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingController(rootView: RootView(model: model, settings: model.settings).environment(\.locale, L10n.language.locale))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: min(preferredWidth, visible.width), height: min(432, visible.height - 60)))
        window.minSize = NSSize(width: L10n.language == .english ? 840 : 680, height: 420)
        let toolbar = NSToolbar(identifier: "TypeBridge.CompactToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setFrameAutosaveName("TypeBridge.CompactWindow")
        window.center()
    }

    @objc private func showWindow() {
        model.workbenchVisible = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.refreshPermission()
    }

    @objc private func showSettings() {
        model.settingsVisible = true
        if settingsWindow == nil { settingsWindow = auxiliaryWindow(L10n.tr("设置"), size: NSSize(width: 560, height: 690), root: SettingsView(model: model, settings: model.settings)) }
        activate(settingsWindow!)
        model.refreshPermission()
    }
    @objc private func showWorkbench() { showWindow() }
    @objc private func showGuide() {
        if guideWindow == nil { guideWindow = auxiliaryWindow(L10n.tr("帮助"), size: NSSize(width: 480, height: 460), root: GuideView(settings: model.settings)) }
        activate(guideWindow!)
    }
    private func showLanguagePacks() {
        if languagePackWindow == nil { languagePackWindow = auxiliaryWindow(L10n.tr("语言包"), size: NSSize(width: 440, height: 280), root: LanguagePackView(model: model)) }
        activate(languagePackWindow!)
        Task { await model.refreshLanguagePack() }
    }
    private func showServices() {
        if serviceWindow == nil {
            serviceWindow = auxiliaryWindow(L10n.tr("模型管理"), size: NSSize(width: 580, height: 460),
                root: ServiceManagementView(model: model, store: model.services))
        }
        activate(serviceWindow!)
    }
    private func auxiliaryWindow<Content: View>(_ title: String, size: NSSize, root: Content) -> NSWindow {
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let host = NSHostingController(rootView: root.environment(\.locale, L10n.language.locale))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(size)
        panel.center()
        return panel
    }
    private func activate(_ panel: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, settingsItemID] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, settingsItemID] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == settingsItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L10n.tr("设置")
        item.toolTip = L10n.tr("设置")
        if let url = Bundle.main.url(forResource: "settings", withExtension: "svg", subdirectory: "Design"), let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            item.image = image
        }
        item.target = self
        item.action = #selector(showSettings)
        item.isBordered = false
        return item
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppBrand.menuBarIcon()
        statusItem.button?.toolTip = AppBrand.name
        let menu = NSMenu()
        addItem(L10n.tr("翻译"), action: #selector(showWorkbench), to: menu)
        addItem(L10n.tr("设置…"), action: #selector(showSettings), to: menu)
        addItem(L10n.tr("帮助"), action: #selector(showGuide), to: menu)
        menu.addItem(.separator())
        addItem(L10n.tr("退出\(AppBrand.name)"), action: #selector(quit), to: menu, key: "q")
        statusItem.menu = menu
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        addItem(L10n.tr("关于\(AppBrand.name)"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: appMenu, target: NSApp)
        appMenu.addItem(.separator())
        addItem(L10n.tr("设置…"), action: #selector(showSettings), to: appMenu, key: ",")
        appMenu.addItem(.separator())
        addItem(L10n.tr("隐藏\(AppBrand.name)"), action: #selector(NSApplication.hide(_:)), to: appMenu, key: "h", target: NSApp)
        addItem(L10n.tr("退出\(AppBrand.name)"), action: #selector(quit), to: appMenu, key: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.tr("编辑"))
        let actions: [(String, Selector, String)] = [
            (L10n.tr("撤销"), Selector(("undo:")), "z"),
            (L10n.tr("剪切"), #selector(NSText.cut(_:)), "x"),
            (L10n.tr("复制"), #selector(NSText.copy(_:)), "c"),
            (L10n.tr("粘贴"), #selector(NSText.paste(_:)), "v"),
            (L10n.tr("全选"), #selector(NSText.selectAll(_:)), "a")
        ]
        for (title, selector, key) in actions { editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "", target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        menu.addItem(item)
    }

    private func showSelection() {
        if selectionPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 276),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.minSize = NSSize(width: 360, height: 300)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingController(rootView: SelectionResultView(model: model, settings: model.settings))
            host.sizingOptions = []
            panel.contentViewController = host
            panel.setContentSize(NSSize(width: 420, height: 276))
            selectionPanel = panel
        }
        guard let panel = selectionPanel else { return }
        model.selectionVisible = true
        panel.title = model.selectionTitle
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let x = min(max(mouse.x + 16, visible.minX + 16), visible.maxX - panel.frame.width - 16)
            let y = min(max(mouse.y - panel.frame.height - 12, visible.minY + 16), visible.maxY - panel.frame.height - 16)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
    }

    private func showFeedback() {
        closeFeedbackPreview()
        guard let state = model.feedback, state.surface == .floating, state.phase.showsFeedback else {
            feedbackPanel?.orderOut(nil)
            return
        }
        if feedbackPanel == nil {
            let panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: FeedbackPanelView(model: model, settings: model.settings))
            feedbackPanel = panel
        }
        guard let panel = feedbackPanel, let host = panel.contentView as? NSHostingView<FeedbackPanelView> else { return }
        panel.hasShadow = state.phase == .failure
        panel.ignoresMouseEvents = state.phase.isActive
        host.rootView = FeedbackPanelView(model: model, settings: model.settings)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let anchor = state.anchor ?? NSRect(origin: mouse, size: .zero)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            panel.setFrame(FeedbackPlacement.frame(size: size, anchor: anchor, visible: screen.visibleFrame), display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    private func closeFeedbackPreview() {
        dismissPreview?.cancel()
        previewPanel?.orderOut(nil)
        previewPanel?.contentView = nil
    }

    /// The same floating component, using clearly marked sample data and no text access.
    private func showFeedbackPreview(_ state: TranslationFeedback) {
        guard !model.busy, state.phase.showsFeedback else { return }
        closeFeedbackPreview()
        if previewPanel == nil {
            let panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = L10n.tr("动效预览")
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            previewPanel = panel
        }
        guard let panel = previewPanel else { return }
        panel.hasShadow = state.phase == .failure
        panel.ignoresMouseEvents = state.phase.isActive
        var preview = state
        preview.title = L10n.tr("预览 · \(state.title)")
        preview.detail = L10n.tr("预览") + (state.detail.isEmpty ? "" : " · \(state.detail)")
        let close: () -> Void = { [weak self] in self?.closeFeedbackPreview() }
        let host = NSHostingView(rootView: FeedbackView(state: preview, style: model.settings.feedbackStyle,
            cancel: close, dismiss: close))
        panel.contentView = host
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            panel.setFrame(FeedbackPlacement.frame(size: host.fittingSize, anchor: CGRect(origin: mouse, size: .zero), visible: screen.visibleFrame), display: true)
        }
        panel.orderFrontRegardless()
        let item = DispatchWorkItem(block: close)
        dismissPreview = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (state.phase == .failure ? 8 : 4), execute: item)
    }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

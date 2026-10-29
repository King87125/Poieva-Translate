import AppKit
import TypeBridgeCore

@MainActor
enum InterfaceLanguageSetup {
    static func prepare() -> Bool {
        let preference = InterfaceLanguagePreference()
        if preference.requiresSelection {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Choose your language / 选择界面语言"
            alert.informativeText = "Poieva Translate"
            alert.addButton(withTitle: "Continue / 继续")
            alert.addButton(withTitle: "Quit / 退出")
            let languages = InterfaceLanguage.allCases
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
            picker.addItems(withTitles: languages.map(\.nativeName))
            picker.selectItem(at: languages.firstIndex(of: preference.effectiveLanguage) ?? 0)
            picker.setAccessibilityLabel("Language / 界面语言")
            alert.accessoryView = picker
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            preference.save(languages[picker.indexOfSelectedItem])
        }
        L10n.configure(preference.effectiveLanguage)
        return true
    }
}

import AppKit

enum AppBrand {
    static let series = "Poieva"
    static let name = "Poieva Translate"

    @MainActor static func installApplicationIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
    }

    @MainActor static func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "poieva-mark", withExtension: "svg", subdirectory: "Design"),
              let vector = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "character.bubble", accessibilityDescription: name)
        }
        vector.size = NSSize(width: 1024, height: 1024)
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            vector.draw(in: NSRect(x: 1.2, y: 0, width: 15.6, height: 18),
                from: NSRect(x: 290, y: 235, width: 476, height: 550), operation: .sourceOver, fraction: 1)
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = name
        return icon
    }
}

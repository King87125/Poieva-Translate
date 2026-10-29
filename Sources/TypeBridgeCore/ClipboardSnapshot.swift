import AppKit

/// A short-lived clipboard transaction; never restores over a newer user copy.
@MainActor
public final class ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    public init(_ pasteboard: NSPasteboard = .general) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    public func restore(ifOwned changeCount: Int, to pasteboard: NSPasteboard = .general) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let restored = items.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

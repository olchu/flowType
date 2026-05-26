import AppKit
import Foundation

struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []

        return ClipboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        let restoredItems = items.map { storedItem in
            let item = NSPasteboardItem()

            for (type, data) in storedItem {
                item.setData(data, forType: type)
            }

            return item
        }

        pasteboard.writeObjects(restoredItems)
    }
}

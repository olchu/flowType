import AppKit
import SwiftUI

@MainActor
final class TranslationPopoverController {
    private var panel: NSPanel?

    func show(_ translation: String, near accessibilityBounds: CGRect?) {
        let view = TranslationPopoverView(text: translation) { [weak self] in
            self?.hide()
        }
        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize
        let panel = panel ?? makePanel()
        panel.contentView = hostingView
        panel.setContentSize(size)
        position(panel, near: accessibilityBounds)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func position(_ panel: NSPanel, near bounds: CGRect?) {
        let point: NSPoint
        if let bounds, let primaryScreen = NSScreen.screens.first {
            point = NSPoint(x: bounds.minX, y: primaryScreen.frame.maxY - bounds.maxY - panel.frame.height - 8)
        } else {
            let mouse = NSEvent.mouseLocation
            point = NSPoint(x: mouse.x + 10, y: mouse.y - panel.frame.height - 10)
        }

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.setFrameOrigin(point)
            return
        }
        let x = min(max(point.x, visibleFrame.minX + 8), visibleFrame.maxX - panel.frame.width - 8)
        let y = min(max(point.y, visibleFrame.minY + 8), visibleFrame.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct TranslationPopoverView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: 360, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6))
        }
        .frame(minWidth: 260, maxWidth: 420)
    }
}

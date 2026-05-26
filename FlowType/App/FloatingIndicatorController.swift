import AppKit
import SwiftUI

@MainActor
final class FloatingIndicatorController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func update(for status: AppStatus) {
        hideTask?.cancel()

        switch status {
        case .recording, .transcribing:
            show(status)
        case .ready:
            scheduleHide()
        case .error:
            if panel?.isVisible == true {
                show(status)
                scheduleHide()
            }
        }
    }

    private func show(_ status: AppStatus) {
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: FloatingIndicatorView(status: status))
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func scheduleHide() {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 72, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }

        let size = panel.contentView?.fittingSize ?? NSSize(width: 72, height: 30)
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.minY + 32

        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

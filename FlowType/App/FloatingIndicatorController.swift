import AppKit
import SwiftUI

@MainActor
final class FloatingIndicatorController {
    private var panel: NSPanel?
    private let model = FloatingIndicatorModel()
    private var hideTask: Task<Void, Never>?
    private var isDismissalInProgress = false
    private var style: IndicatorStyle = .bars
    /// Waves collapse into the orb and fade, which takes longer than the pill.
    private var dismissalDuration: Duration {
        style == .waves ? .milliseconds(520) : .milliseconds(190)
    }

    func update(for status: AppStatus, isModelLoading: Bool, audioLevel: Double = 0, style: IndicatorStyle) {
        self.style = style
        let forceNewPresentation = isDismissalInProgress
        cancelPendingHide()

        if isModelLoading {
            present(.loading, forceNewPresentation: forceNewPresentation)
            return
        }

        switch status {
        case .recording, .transcribing:
            present(.status(status), audioLevel: audioLevel, forceNewPresentation: forceNewPresentation)
        case .ready:
            beginDismissal()
        case .error:
            guard panel?.isVisible == true else { return }
            present(.status(status), audioLevel: audioLevel, forceNewPresentation: forceNewPresentation)
            scheduleHide(after: .milliseconds(850))
        }
    }

    func showPasted() {
        let forceNewPresentation = isDismissalInProgress
        cancelPendingHide()

        present(.pasted, forceNewPresentation: forceNewPresentation)
        scheduleHide(after: .milliseconds(650))
    }

    private func present(
        _ content: FloatingIndicatorModel.Content,
        audioLevel: Double = 0,
        forceNewPresentation: Bool
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let startsNewPresentation = !panel.isVisible || forceNewPresentation

        model.show(content, audioLevel: audioLevel, style: style, startsNewPresentation: startsNewPresentation)

        position(panel)
        if startsNewPresentation {
            panel.orderFrontRegardless()
        }
    }

    private func beginDismissal() {
        guard panel?.isVisible == true else {
            panel?.orderOut(nil)
            return
        }

        model.beginDismissal()
        isDismissalInProgress = true
        let dismissalDuration = dismissalDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: dismissalDuration)
            guard !Task.isCancelled else { return }
            self?.isDismissalInProgress = false
            self?.panel?.orderOut(nil)
        }
    }

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
        isDismissalInProgress = false
    }

    private func scheduleHide(after delay: Duration) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.beginDismissal()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: style.indicatorSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: FloatingIndicatorView(model: model))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }

        // The waves frame has a transparent glow margin, so it can dip
        // slightly behind the Dock and still keep the lines above it.
        let dockAwareBottomInset: CGFloat = style == .waves ? -10 : 20
        let size = style.indicatorSize
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.minY + dockAwareBottomInset
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        // Called on every audio level update while recording.
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }
}

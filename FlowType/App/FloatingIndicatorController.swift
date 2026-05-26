import AppKit
import SwiftUI

@MainActor
final class FloatingIndicatorController {
    private var panel: NSPanel?
    private let model = FloatingIndicatorModel()
    private var hideTask: Task<Void, Never>?
    private var isDismissalInProgress = false
    private let dismissalDuration: Duration = .milliseconds(190)

    func update(
        for status: AppStatus,
        isModelLoading: Bool,
        audioLevel: Double = 0,
        microphoneSensitivity: Double = 0.5
    ) {
        let shouldReplayPresentation = isDismissalInProgress
        cancelPendingHide()

        if isModelLoading {
            showLoading(forceNewPresentation: shouldReplayPresentation)
            return
        }

        switch status {
        case .recording, .transcribing:
            show(
                status,
                audioLevel: audioLevel,
                microphoneSensitivity: microphoneSensitivity,
                forceNewPresentation: shouldReplayPresentation
            )
        case .ready:
            hide()
        case .error:
            if panel?.isVisible == true {
                show(
                    status,
                    audioLevel: audioLevel,
                    microphoneSensitivity: microphoneSensitivity,
                    forceNewPresentation: shouldReplayPresentation
                )
                scheduleHide()
            }
        }
    }

    private func showLoading(forceNewPresentation: Bool = false) {
        let panel = panel ?? makePanel()
        let startsNewPresentation = !panel.isVisible || forceNewPresentation

        model.updateLoading(startsNewPresentation: startsNewPresentation)

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func show(
        _ status: AppStatus,
        audioLevel: Double,
        microphoneSensitivity: Double,
        forceNewPresentation: Bool = false
    ) {
        let panel = panel ?? makePanel()
        let startsNewPresentation = !panel.isVisible || forceNewPresentation

        model.update(
            status: status,
            audioLevel: audioLevel,
            microphoneSensitivity: microphoneSensitivity,
            startsNewPresentation: startsNewPresentation
        )

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        beginDismissal(cancelExistingTask: true)
    }

    private func beginDismissal(cancelExistingTask: Bool) {
        if cancelExistingTask {
            hideTask?.cancel()
        }

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
            await MainActor.run {
                self?.isDismissalInProgress = false
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
        isDismissalInProgress = false
    }

    private func scheduleHide() {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.beginDismissal(cancelExistingTask: false)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 72, height: 22),
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

        let size = panel.contentView?.fittingSize ?? NSSize(width: 72, height: 22)
        let dockAwareBottomInset: CGFloat = 20
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.minY + dockAwareBottomInset

        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

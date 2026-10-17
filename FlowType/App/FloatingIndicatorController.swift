import AppKit
import SwiftUI

@MainActor
final class FloatingIndicatorController {
    private var panel: NSPanel?
    private let model = FloatingIndicatorModel()
    private var hideTask: Task<Void, Never>?
    /// The pasted confirmation hides itself once it has been seen, so the
    /// ready status that follows a paste must not cut it short.
    private var isShowingPasted = false

    func update(for status: AppStatus, isModelLoading: Bool, style: IndicatorStyle, waveColor: WaveColor) {
        if isModelLoading {
            cancelPendingHide()
            present(.loading, style: style, waveColor: waveColor)
            return
        }

        switch status {
        case .recording, .transcribing:
            cancelPendingHide()
            present(.status(status), style: style, waveColor: waveColor)
        case .ready:
            guard !isShowingPasted else { return }
            cancelPendingHide()
            beginDismissal()
        case .error:
            guard panel?.isVisible == true else { return }
            cancelPendingHide()
            present(.status(status), style: style, waveColor: waveColor)
            scheduleHide(after: .milliseconds(850))
        }
    }

    func showPasted() {
        cancelPendingHide()
        present(.pasted, style: model.style, waveColor: model.waveColor)
        scheduleHide(after: model.style.pastedHoldDuration)
    }

    /// Separate from `update`: the level changes at buffer rate and only the
    /// running animations need it.
    func setAudioLevel(_ level: Double) {
        model.audioLevel = level
    }

    private func present(_ content: FloatingIndicatorModel.Content, style: IndicatorStyle, waveColor: WaveColor) {
        let panel = panel ?? makePanel(style: style)
        self.panel = panel
        isShowingPasted = content == .pasted
        // An interrupted dismissal is taken back by `show`; only a hidden
        // panel starts over with the intro.
        let startsNewPresentation = !panel.isVisible

        model.show(content, style: style, waveColor: waveColor, startsNewPresentation: startsNewPresentation)

        position(panel)
        if startsNewPresentation {
            panel.orderFrontRegardless()
        }
    }

    private func beginDismissal() {
        isShowingPasted = false
        guard panel?.isVisible == true else {
            panel?.orderOut(nil)
            return
        }

        model.beginDismissal()
        let dismissalDuration = model.style.dismissalDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dismissalDuration))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func scheduleHide(after delay: Duration) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.beginDismissal()
        }
    }

    private func makePanel(style: IndicatorStyle) -> NSPanel {
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

        let style = model.style
        let size = style.indicatorSize
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.minY + style.bottomInset
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

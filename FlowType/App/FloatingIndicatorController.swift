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
    /// Speaks into the indicator while the user places it, so it shows
    /// moving.
    private var demoVoice: Task<Void, Never>?
    private var dragHandle: NSView?
    /// Where the indicator was when placing began, to tell a drag from none.
    private var frameBeforePositioning: NSRect?
    /// The centre the user placed the indicator at, in global screen
    /// coordinates; nil above the Dock.
    var placement: CGPoint?

    var isPositioning: Bool {
        model.isPositioning
    }

    func update(for status: AppStatus, isModelLoading: Bool, appearance: IndicatorAppearance) {
        // Placing the indicator keeps it up until the user is done; a new
        // style or colour shows on it right away, where it was dragged.
        if isPositioning, let panel {
            let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            model.show(.status(.recording), appearance: appearance, startsNewPresentation: false)
            let size = appearance.style.indicatorSize
            panel.setFrame(NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height), display: true)
            return
        }
        if isModelLoading {
            cancelPendingHide()
            present(.loading, appearance: appearance)
            return
        }

        switch status {
        case .recording, .transcribing:
            cancelPendingHide()
            present(.status(status), appearance: appearance)
        case .ready:
            guard !isShowingPasted else { return }
            cancelPendingHide()
            beginDismissal()
        case .error:
            guard panel?.isVisible == true else { return }
            cancelPendingHide()
            present(.status(status), appearance: appearance)
            scheduleHide(after: .milliseconds(850))
        }
    }

    func showPasted() {
        cancelPendingHide()
        present(.pasted, appearance: model.appearance)
        scheduleHide(after: model.style.pastedHoldDuration)
    }

    /// Separate from `update`: the level changes at buffer rate and only the
    /// running animations need it.
    /// `bands` is the spectrum's shape; the indicator scales it by `level`.
    func setAudioLevel(_ level: Double, bands: SpectrumBands) {
        model.audioLevel = level
        model.audioBands = bands
    }

    /// Shows the indicator where it would appear, draggable to anywhere on
    /// any screen. Returns whether placing started.
    func beginPositioning(appearance: IndicatorAppearance) -> Bool {
        guard !isPositioning else { return true }
        cancelPendingHide()
        present(.status(.recording), appearance: appearance)
        guard let panel, let contentView = panel.contentView else { return false }

        panel.ignoresMouseEvents = false
        let handle = DragHandleView(frame: contentView.bounds)
        handle.autoresizingMask = [.width, .height]
        contentView.addSubview(handle)
        dragHandle = handle
        frameBeforePositioning = panel.frame
        model.isPositioning = true
        demoVoice = Task { [model] in
            await DemoVoice.drive(model)
        }
        return true
    }

    /// Ends placing the indicator; the caller then shows whatever it should
    /// show. Returns its new centre when `keeps` is true and it was moved,
    /// kept on its screen.
    func endPositioning(keeps: Bool) -> CGPoint? {
        guard isPositioning, let panel else { return nil }
        demoVoice?.cancel()
        demoVoice = nil
        dragHandle?.removeFromSuperview()
        dragHandle = nil
        panel.ignoresMouseEvents = true
        model.isPositioning = false
        setAudioLevel(0, bands: .zero)

        let wasMoved = panel.frame.origin != frameBeforePositioning?.origin
        frameBeforePositioning = nil
        guard keeps, wasMoved, let bounds = (panel.screen ?? NSScreen.main)?.frame else { return nil }
        return CGPoint(
            x: min(max(panel.frame.midX, bounds.minX), bounds.maxX),
            y: min(max(panel.frame.midY, bounds.minY), bounds.maxY)
        )
    }

    private func present(_ content: FloatingIndicatorModel.Content, appearance: IndicatorAppearance) {
        let panel = panel ?? makePanel(style: appearance.style)
        self.panel = panel
        isShowingPasted = content == .pasted
        // An interrupted dismissal is taken back by `show`; only a hidden
        // panel starts over with the intro.
        let startsNewPresentation = !panel.isVisible

        model.show(content, appearance: appearance, startsNewPresentation: startsNewPresentation)

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
        let style = model.style
        let size = style.indicatorSize

        // Centred where the user placed it, even if the frame's transparent
        // margin runs off the screen: that is how the drawing gets into a
        // corner. Above the Dock if that screen is gone. The edges count:
        // the centre is kept on them when dragged past, and `contains`
        // leaves the top and right ones out.
        if let centre = placement, NSScreen.screens.contains(where: { screen in
            (screen.frame.minX...screen.frame.maxX).contains(centre.x)
                && (screen.frame.minY...screen.frame.maxY).contains(centre.y)
        }) {
            panel.setFrame(NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height), display: true)
            return
        }

        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.minY + style.bottomInset
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
}

/// Lies over the indicator while it is placed and hands a drag to the
/// window, which moves it the way the system moves windows.
private final class DragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // The panel never becomes key, so cursor rects don't apply to it; a
    // tracking area that is always active sets the open hand instead.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }
}

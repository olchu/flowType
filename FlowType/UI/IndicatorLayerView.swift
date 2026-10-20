import AppKit

/// Shared driver of the layer-drawn indicator styles: runs a WaveEngine on a
/// display link while the indicator is presented, and stops once the
/// dismissal has played out. Subclasses draw each frame in `render`.
class IndicatorLayerView: NSView {
    /// Read every frame for the audio level, which is not published.
    private let model: FloatingIndicatorModel
    private let style: IndicatorStyle
    private let engine = WaveEngine()
    private var displayLink: CADisplayLink?
    private var stopTime: CFTimeInterval?

    private var mode: WaveEngine.Mode = .processing
    private var presentationID: Int?
    private var isDismissing = false

    init(frame frameRect: NSRect, model: FloatingIndicatorModel, style: IndicatorStyle) {
        self.model = model
        self.style = style
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(mode: WaveEngine.Mode, presentationID: Int, isDismissing: Bool) {
        self.mode = mode
        let now = CACurrentMediaTime()

        if presentationID != self.presentationID {
            self.presentationID = presentationID
            self.isDismissing = false
            engine.present(at: now)
            didStartPresentation()
            stopTime = nil
            startDisplayLink()
        }

        guard isDismissing != self.isDismissing else { return }
        self.isDismissing = isDismissing
        if isDismissing {
            engine.dismiss(at: now)
            // Stop redrawing once the dismissal has faded and the panel is hidden.
            stopTime = now + style.dismissalDuration + 0.2
        } else {
            // Dismissal was taken back: grow back from the current state.
            engine.resume()
            stopTime = nil
            startDisplayLink()
        }
    }

    /// Called when a new presentation starts, before its first frame.
    func didStartPresentation() {}

    func render(_ frame: WaveEngine.Frame) {}

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The display link retains its target.
        if newWindow == nil {
            stopDisplayLink()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && presentationID != nil && stopTime == nil {
            startDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let stopTime, now >= stopTime {
            stopDisplayLink()
            return
        }
        render(engine.advance(mode: mode, audioLevel: model.audioLevel, at: now))
    }
}

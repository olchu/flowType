import AppKit
import SwiftUI

/// Waves style of the floating indicator: a glowing orb that stretches into
/// voice-reactive ribbons, a pulse of light running along them while
/// processing, a flash on
/// paste, and the collapse back into the orb on dismissal.
///
/// Drawn with Core Animation layers instead of a SwiftUI Canvas: Canvas
/// starts SwiftUI's Metal renderer, which costs about 95 MB of GPU memory,
/// while shape layers and their shadows are composited by the window server.
struct WaveIndicatorView: NSViewRepresentable {
    @ObservedObject var model: FloatingIndicatorModel

    /// 240x80 waves plus room for the glow.
    static let size = CGSize(width: 280, height: 116)

    func makeNSView(context: Context) -> WaveLayerView {
        WaveLayerView(frame: CGRect(origin: .zero, size: Self.size))
    }

    func updateNSView(_ view: WaveLayerView, context: Context) {
        view.update(
            mode: mode,
            audioLevel: model.audioLevel,
            presentationID: model.presentationID,
            dismissalID: model.dismissalID
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveLayerView, context: Context) -> CGSize? {
        Self.size
    }

    private var mode: WaveEngine.Mode {
        switch model.content {
        case .status(.recording):
            .listening
        case .pasted:
            .pasted
        case .loading, .status:
            .processing
        }
    }
}

final class WaveLayerView: NSView {
    private struct Strand {
        let cycles: Double
        let speed: Double
        let phase: Double
        let swellSpeed: Double
        let gain: Double
        let color: CGColor
    }

    private static let cyan = CGColor(red: 0.38, green: 0.95, blue: 0.96, alpha: 1)
    private static let blue = CGColor(red: 0.34, green: 0.6, blue: 1.0, alpha: 1)
    private static let glowMargin = CGSize(width: 20, height: 18)

    // Opposite speeds make strands drift through each other.
    private static let strands: [Strand] = [
        Strand(cycles: 1.6, speed: 3.1, phase: 0.0, swellSpeed: 1.3, gain: 1.0, color: cyan),
        Strand(cycles: 2.1, speed: -2.4, phase: 1.9, swellSpeed: -0.9, gain: 0.85, color: blue),
        Strand(cycles: 1.2, speed: 2.0, phase: 3.6, swellSpeed: 0.7, gain: 0.7, color: cyan),
        Strand(cycles: 2.6, speed: -3.4, phase: 5.0, swellSpeed: 1.1, gain: 0.55, color: blue),
        Strand(cycles: 1.9, speed: 4.2, phase: 2.4, swellSpeed: -1.5, gain: 0.4, color: cyan),
        // Thin fibers that fill the bundle out.
        Strand(cycles: 1.4, speed: -1.7, phase: 4.3, swellSpeed: 0.5, gain: 0.5, color: blue),
        Strand(cycles: 2.3, speed: 2.7, phase: 0.9, swellSpeed: -1.2, gain: 0.35, color: cyan),
        Strand(cycles: 1.1, speed: -3.8, phase: 2.9, swellSpeed: 1.6, gain: 0.3, color: blue),
        Strand(cycles: 2.9, speed: 1.5, phase: 5.6, swellSpeed: -0.6, gain: 0.25, color: cyan),
    ]

    private let engine = WaveEngine()
    private let strandsLayer = CALayer()
    private let auraLayer = CAShapeLayer()
    private let fadeMask = CAGradientLayer()
    private let orbLayer = CAGradientLayer()
    private var haloLayers: [CAShapeLayer] = []
    private var coreLayers: [CAShapeLayer] = []
    private var displayLink: CADisplayLink?
    private var stopTime: CFTimeInterval?

    private var mode: WaveEngine.Mode = .processing
    private var audioLevel = 0.0
    private var presentationID: Int?
    private var dismissalID: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(mode: WaveEngine.Mode, audioLevel: Double, presentationID: Int, dismissalID: Int) {
        self.mode = mode
        self.audioLevel = audioLevel

        if presentationID != self.presentationID {
            self.presentationID = presentationID
            self.dismissalID = dismissalID
            engine.present(at: CACurrentMediaTime())
            stopTime = nil
            startDisplayLink()
        } else if dismissalID != self.dismissalID {
            self.dismissalID = dismissalID
            let now = CACurrentMediaTime()
            engine.dismiss(at: now)
            // Stop redrawing once the orb has faded and the panel is hidden.
            stopTime = now + 0.7
        }
    }

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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [strandsLayer, auraLayer, fadeMask, orbLayer] + haloLayers + coreLayers {
            layer.contentsScale = scale
        }
    }

    private func setUpLayers() {
        guard let layer else { return }

        strandsLayer.frame = bounds
        strandsLayer.mask = fadeMask
        layer.addSublayer(strandsLayer)

        // Fades every strand and its glow out towards both ends; while
        // processing it also carries the travelling pulse.
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.locations = Self.maskLocations.map { NSNumber(value: $0) }

        // Dark haze behind the glow, so the bundle reads as plasma on any
        // background. Normal compositing: it darkens what is underneath.
        auraLayer.frame = bounds
        auraLayer.shadowColor = CGColor.black
        auraLayer.shadowOffset = .zero
        auraLayer.shadowRadius = 14
        auraLayer.shadowOpacity = 0.75
        strandsLayer.addSublayer(auraLayer)

        // Glow comes from shadows with explicit paths: the window server
        // blurs them, so there is no hard edge and no in-process rendering.
        haloLayers = Self.strands.map { strand in
            let halo = CAShapeLayer()
            halo.shadowColor = strand.color
            halo.shadowOffset = .zero
            halo.shadowRadius = 10
            halo.shadowOpacity = 1
            return halo
        }
        coreLayers = Self.strands.map { strand in
            let core = CAShapeLayer()
            core.fillColor = strand.color
            core.shadowColor = strand.color
            core.shadowOffset = .zero
            core.shadowRadius = 3.5
            core.shadowOpacity = 0.5
            return core
        }
        for sublayer in haloLayers + coreLayers {
            // Additive, so crossings light up like the Canvas version did.
            sublayer.compositingFilter = "plusL"
            sublayer.frame = bounds
            strandsLayer.addSublayer(sublayer)
        }

        orbLayer.type = .radial
        orbLayer.colors = [
            CGColor.white,
            CGColor.white,
            Self.cyan,
            Self.cyan.copy(alpha: 0.3)!,
            Self.cyan.copy(alpha: 0)!,
        ]
        orbLayer.locations = [0, 0.12, 0.3, 0.55, 1]
        orbLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        orbLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(orbLayer)

        render(WaveEngine.Frame(level: 0, clock: 0, spread: 0, visibility: 0, flash: 0, scan: 0, scanAmount: 0))
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
        render(engine.advance(mode: mode, audioLevel: audioLevel, at: now))
    }

    private func render(_ frame: WaveEngine.Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Waves live in the inner rect; the margin is room for the glow.
        let rect = bounds.insetBy(dx: Self.glowMargin.width, dy: Self.glowMargin.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let width = rect.width * frame.spread

        strandsLayer.isHidden = width <= 1
        if width > 1 {
            // Keep a faint moving line in silence; sqrt lifts typical speech levels.
            let amplitude = (rect.height / 2 - 3) * (0.06 + 0.94 * sqrt(frame.level)) * 1.6 * frame.spread
            // Overlapping strands get bright when flat, so dim them in silence.
            let brightness = (0.45 + 0.55 * min(1, frame.level * 2.5) + frame.flash) * frame.visibility
            let waveRect = CGRect(x: center.x - width / 2, y: rect.minY, width: width, height: rect.height)
            fadeMask.frame = CGRect(x: waveRect.minX, y: 0, width: width, height: bounds.height)
            let aura = CGMutablePath()

            for (index, strand) in Self.strands.enumerated() {
                let shapes = Self.shapes(for: strand, in: waveRect, amplitude: amplitude, frame: frame)
                aura.addPath(shapes.wideGlow)
                let halo = haloLayers[index]
                halo.shadowPath = shapes.wideGlow
                halo.opacity = Float(min(1, 0.3 * strand.gain * brightness))
                let core = coreLayers[index]
                core.path = shapes.ribbon
                core.shadowPath = shapes.nearGlow
                core.opacity = Float(min(1, (0.35 + 0.45 * strand.gain) * brightness))
            }
            auraLayer.shadowPath = aura
            auraLayer.opacity = Float(frame.visibility)

            fadeMask.colors = Self.maskColors(scan: frame.scan, amount: frame.scanAmount)
        }

        let orbOpacity = frame.visibility * pow(1 - frame.spread, 1.5)
        orbLayer.isHidden = orbOpacity <= 0.01
        let radius = 16 * (0.4 + 0.6 * frame.visibility)
        orbLayer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        orbLayer.position = center
        orbLayer.opacity = Float(orbOpacity)
    }

    private static let maskLocations = (0...16).map { Double($0) / 16 }

    /// Alpha along the strands: fades out at both ends and, while
    /// processing, dims everything except a soft band around `scan`.
    private static func maskColors(scan: Double, amount: Double) -> [CGColor] {
        let center = 0.5 + scan * 0.3
        return maskLocations.map { location in
            let edgeFade = min(1, location / 0.22, (1 - location) / 0.22)
            let pulse = exp(-pow((location - center) / 0.13, 2))
            let dimmed = 1 - amount * 0.45 * (1 - pulse)
            return CGColor(gray: 0, alpha: edgeFade * dimmed)
        }
    }

    /// A ribbon that is hairline at the ends and thickest in the middle,
    /// plus wider outlines of it that only cast the glow.
    private static func shapes(
        for strand: Strand,
        in rect: CGRect,
        amplitude: CGFloat,
        frame: WaveEngine.Frame
    ) -> (ribbon: CGPath, nearGlow: CGPath, wideGlow: CGPath) {
        let steps = max(2, Int(rect.width / 2))
        let limit = Double(rect.height / 2 - 3)
        let time = frame.clock
        let maxHalfWidth = (0.8 + 1.0 * frame.level) * strand.gain
        var points: [CGPoint] = []
        var halfWidths: [CGFloat] = []
        var envelopes: [CGFloat] = []
        points.reserveCapacity(steps + 1)
        halfWidths.reserveCapacity(steps + 1)
        envelopes.reserveCapacity(steps + 1)

        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            // Bell curve: flat thin ends, full swing only in the middle.
            let envelope = exp(-pow((progress - 0.5) / 0.2, 2))
            // Slowly moving swell so humps rise and fall along the strand.
            let swell = 0.65 + 0.35 * sin(progress * .pi * 1.6 + time * strand.swellSpeed + strand.phase)
            let wave = sin(progress * .pi * 2 * strand.cycles + time * strand.speed + strand.phase)
            // Louder speech adds a faster ripple on top of the main wave.
            let ripple = frame.level * 0.3 * sin(progress * .pi * 2 * strand.cycles * 2.3 - time * strand.speed * 1.7)
            let raw = Double(amplitude) * strand.gain * envelope * swell * (wave + ripple)
            // Soft limit keeps loud peaks inside the frame without flat tops.
            let offset = limit * tanh(raw / limit)

            points.append(CGPoint(x: rect.minX + rect.width * progress, y: rect.midY + offset))
            halfWidths.append(CGFloat(0.3 + maxHalfWidth * envelope))
            envelopes.append(CGFloat(envelope))
        }

        // Unit normals, so steep slopes keep their thickness.
        let normals = points.indices.map { index in
            let previous = points[max(index - 1, 0)]
            let next = points[min(index + 1, points.count - 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(hypot(dx, dy), 0.001)
            return CGPoint(x: -dy / length, y: dx / length)
        }

        // Glow outlines widen only towards the middle, so the converging
        // ends of all strands don't add up into a bright bar.
        func ribbon(widenedBy extra: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for index in points.indices {
                let width = halfWidths[index] + extra * envelopes[index]
                let point = CGPoint(x: points[index].x + normals[index].x * width, y: points[index].y + normals[index].y * width)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            for index in points.indices.reversed() {
                let width = halfWidths[index] + extra * envelopes[index]
                path.addLine(to: CGPoint(x: points[index].x - normals[index].x * width, y: points[index].y - normals[index].y * width))
            }
            path.closeSubpath()
            return path
        }

        return (ribbon(widenedBy: 0), ribbon(widenedBy: 1.5), ribbon(widenedBy: 5))
    }
}

/// Per-frame state for WaveIndicatorView. Eases the chunky level updates,
/// keeps a wave clock that runs faster while speaking (so motion speeds up
/// without phase jumps), and drives the orb intro and collapse.
final class WaveEngine {
    enum Mode {
        case listening
        case processing
        case pasted
    }

    struct Frame {
        var level: Double
        var clock: Double
        /// 0 is the collapsed orb, 1 is full-width waves.
        var spread: Double
        var visibility: Double
        var flash: Double
        /// Processing pulse position in -1...1.
        var scan: Double
        /// How much the processing pulse shows, eased in and out.
        var scanAmount: Double
    }

    private var level = 0.0
    private var clock = 0.0
    private var spread = 0.0
    private var visibility = 0.0
    private var scanAmount = 0.0
    private var lastTime: TimeInterval?
    private var presentedAt: TimeInterval = 0
    private var dismissedAt: TimeInterval?
    private var pastedAt: TimeInterval?

    func present(at time: TimeInterval) {
        presentedAt = time
        dismissedAt = nil
        pastedAt = nil
        lastTime = nil
        level = 0
        spread = 0
        visibility = 0
        scanAmount = 0
    }

    func dismiss(at time: TimeInterval) {
        if dismissedAt == nil {
            dismissedAt = time
        }
    }

    func advance(mode: Mode, audioLevel: Double, at time: TimeInterval) -> Frame {
        let elapsed = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time

        let targetLevel: Double
        switch mode {
        case .listening:
            targetLevel = audioLevel
        case .processing:
            targetLevel = 0.1 + 0.05 * sin(time * 2.2)
        case .pasted:
            targetLevel = 0
            if pastedAt == nil {
                pastedAt = time
            }
        }
        level = Self.ease(level, toward: targetLevel, rate: targetLevel > level ? 35 : 10, elapsed: elapsed)
        clock += elapsed * (1 + 1.8 * level)
        scanAmount = Self.ease(scanAmount, toward: mode == .processing ? 1 : 0, rate: 6, elapsed: elapsed)

        // The orb pops in, then stretches into waves; dismissal reverses it.
        if let dismissedAt {
            spread = Self.ease(spread, toward: 0, rate: 12, elapsed: elapsed)
            let target = time - dismissedAt > 0.22 ? 0.0 : 1.0
            visibility = Self.ease(visibility, toward: target, rate: 16, elapsed: elapsed)
        } else {
            let target = time - presentedAt > 0.12 ? 1.0 : 0.0
            spread = Self.ease(spread, toward: target, rate: 10, elapsed: elapsed)
            visibility = Self.ease(visibility, toward: 1, rate: 22, elapsed: elapsed)
        }

        return Frame(
            level: level,
            clock: clock,
            spread: spread,
            visibility: visibility,
            flash: pastedAt.map { exp(-(time - $0) * 5) } ?? 0,
            scan: sin(time * 2.4),
            scanAmount: scanAmount
        )
    }

    private static func ease(_ value: Double, toward target: Double, rate: Double, elapsed: Double) -> Double {
        value + (target - value) * (1 - exp(-rate * elapsed))
    }
}

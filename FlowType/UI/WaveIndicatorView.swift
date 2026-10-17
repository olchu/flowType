import AppKit
import SwiftUI

/// Waves style of the floating indicator: a glowing orb that stretches into
/// voice-reactive ribbons, a pulse of light running along them while
/// processing, a flash on paste, and the collapse back into the orb on
/// dismissal.
///
/// Drawn with Core Animation layers instead of a SwiftUI Canvas: Canvas
/// starts SwiftUI's Metal renderer, which costs about 95 MB of GPU memory,
/// while shape layers and their shadows are composited by the window server.
struct WaveIndicatorView: NSViewRepresentable {
    @ObservedObject var model: FloatingIndicatorModel

    /// 240x80 waves plus room for the glow.
    static let size = CGSize(width: 280, height: 116)

    func makeNSView(context: Context) -> WaveLayerView {
        WaveLayerView(frame: CGRect(origin: .zero, size: Self.size), model: model)
    }

    func updateNSView(_ view: WaveLayerView, context: Context) {
        view.update(mode: mode, presentationID: model.presentationID, isDismissing: model.isDismissing)
        view.apply(model.waveColor)
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
        /// Strands alternate between the palette's two colours.
        let isPrimary: Bool
    }

    private static let glowMargin = CGSize(width: 20, height: 18)

    // Opposite speeds make strands drift through each other.
    private static let strands: [Strand] = [
        Strand(cycles: 1.6, speed: 3.1, phase: 0.0, swellSpeed: 1.3, gain: 1.0, isPrimary: true),
        Strand(cycles: 2.1, speed: -2.4, phase: 1.9, swellSpeed: -0.9, gain: 0.85, isPrimary: false),
        Strand(cycles: 1.2, speed: 2.0, phase: 3.6, swellSpeed: 0.7, gain: 0.7, isPrimary: true),
        Strand(cycles: 2.6, speed: -3.4, phase: 5.0, swellSpeed: 1.1, gain: 0.55, isPrimary: false),
        Strand(cycles: 1.9, speed: 4.2, phase: 2.4, swellSpeed: -1.5, gain: 0.4, isPrimary: true),
        // Thin fibers that fill the bundle out.
        Strand(cycles: 1.4, speed: -1.7, phase: 4.3, swellSpeed: 0.5, gain: 0.5, isPrimary: false),
        Strand(cycles: 2.3, speed: 2.7, phase: 0.9, swellSpeed: -1.2, gain: 0.35, isPrimary: true),
        Strand(cycles: 1.1, speed: -3.8, phase: 2.9, swellSpeed: 1.6, gain: 0.3, isPrimary: false),
        Strand(cycles: 2.9, speed: 1.5, phase: 5.6, swellSpeed: -0.6, gain: 0.25, isPrimary: true),
    ]

    /// Read every frame for the audio level, which is not published.
    private let model: FloatingIndicatorModel
    private let engine = WaveEngine()
    private let strandsLayer = CALayer()
    private let fadeMask = CAGradientLayer()
    private let orbLayer = CAGradientLayer()
    private var haloLayers: [CAShapeLayer] = []
    private var coreLayers: [CAShapeLayer] = []
    private var displayLink: CADisplayLink?
    private var stopTime: CFTimeInterval?
    private var waveColor: WaveColor?
    private var appliedAppearance: WaveAppearance?
    private var envelopeCache: [Double] = []
    private var maskScanAmount: Double?

    private var mode: WaveEngine.Mode = .processing
    private var presentationID: Int?
    private var isDismissing = false

    init(frame frameRect: NSRect, model: FloatingIndicatorModel) {
        self.model = model
        super.init(frame: frameRect)
        wantsLayer = true
        setUpLayers()
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
            stopTime = nil
            startDisplayLink()
        }

        guard isDismissing != self.isDismissing else { return }
        self.isDismissing = isDismissing
        if isDismissing {
            engine.dismiss(at: now)
            // Stop redrawing once the orb has faded and the panel is hidden.
            stopTime = now + IndicatorStyle.waves.dismissalDuration + 0.2
        } else {
            // Dismissal was taken back: grow back from the current state.
            engine.resume()
            stopTime = nil
            startDisplayLink()
        }
    }

    func apply(_ waveColor: WaveColor) {
        guard waveColor != self.waveColor else { return }
        self.waveColor = waveColor
        applyStyle()
    }

    /// Colours, glows and blending from the theme and the current tuning.
    private func applyStyle() {
        let appearance = WaveAppearanceStore.shared.appearance
        appliedAppearance = appearance
        let palette = (waveColor ?? .blue).palette
        // Additive, so crossings light up like the Canvas version did.
        let filter = appearance.usesAdditiveBlending ? "plusL" : nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (index, strand) in Self.strands.enumerated() {
            let color = strand.isPrimary ? palette.primary : palette.secondary
            let halo = haloLayers[index]
            halo.isHidden = !appearance.showsHalo
            halo.shadowColor = color.mixedWithWhite(appearance.haloWhiteness)
            halo.shadowRadius = appearance.haloRadius
            halo.compositingFilter = filter

            let core = coreLayers[index]
            core.fillColor = appearance.showsLines
                ? color.mixedWithWhite(appearance.lineWhiteness).copy(alpha: appearance.lineOpacity)
                : nil
            core.shadowColor = color.mixedWithWhite(appearance.glowWhiteness)
            core.shadowRadius = appearance.glowRadius
            core.shadowOpacity = appearance.showsGlow ? Float(appearance.glowOpacity) : 0
            core.compositingFilter = filter
        }
        orbLayer.colors = [
            CGColor.white,
            CGColor.white,
            palette.primary,
            palette.primary.copy(alpha: 0.3)!,
            palette.primary.copy(alpha: 0)!,
        ]
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
        for layer in [strandsLayer, fadeMask, orbLayer] + haloLayers + coreLayers {
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

        // Glow comes from shadows with explicit paths: the window server
        // blurs them, so there is no hard edge and no in-process rendering.
        // Radii, colours and blending are set by `applyStyle`.
        haloLayers = Self.strands.map { _ in
            let halo = CAShapeLayer()
            halo.shadowOffset = .zero
            halo.shadowOpacity = 1
            return halo
        }
        coreLayers = Self.strands.map { _ in
            let core = CAShapeLayer()
            core.shadowOffset = .zero
            return core
        }
        for sublayer in haloLayers + coreLayers {
            sublayer.frame = bounds
            strandsLayer.addSublayer(sublayer)
        }

        orbLayer.type = .radial
        orbLayer.locations = [0, 0.12, 0.3, 0.55, 1]
        orbLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        orbLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(orbLayer)

        apply(.blue)
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
        render(engine.advance(mode: mode, audioLevel: model.audioLevel, at: now))
    }

    private func render(_ frame: WaveEngine.Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let appearance = WaveAppearanceStore.shared.appearance
        if appearance != appliedAppearance {
            applyStyle()
        }

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
            let envelopes = envelopeProfile(steps: max(2, Int(width / 2)))

            for (index, strand) in Self.strands.enumerated() {
                let shapes = Self.shapes(
                    for: strand,
                    in: waveRect,
                    envelopes: envelopes,
                    amplitude: amplitude,
                    frame: frame,
                    appearance: appearance
                )
                let halo = haloLayers[index]
                halo.shadowPath = shapes.wideGlow
                halo.opacity = Float(min(1, appearance.haloOpacity * strand.gain * brightness))
                let core = coreLayers[index]
                core.path = shapes.ribbon
                core.shadowPath = shapes.nearGlow
                core.opacity = Float(min(1, (0.35 + 0.45 * strand.gain) * brightness))
            }

            // Outside processing the mask is static; skip rebuilding it.
            let scanAmount = frame.scanAmount < 0.001 ? 0 : frame.scanAmount
            if scanAmount > 0 || maskScanAmount != 0 {
                fadeMask.colors = Self.maskColors(scan: frame.scan, amount: scanAmount)
                maskScanAmount = scanAmount
            }
        }

        let orbOpacity = frame.visibility * pow(1 - frame.spread, 1.5)
        orbLayer.isHidden = orbOpacity <= 0.01 || !appearance.showsOrb
        let radius = 16 * (0.4 + 0.6 * frame.visibility)
        orbLayer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        orbLayer.position = center
        orbLayer.opacity = Float(orbOpacity)
    }

    /// Bell curve along a strand: flat thin ends, full swing only in the
    /// middle. Shared by all strands; recomputed only when the width changes.
    private func envelopeProfile(steps: Int) -> [Double] {
        if envelopeCache.count != steps + 1 {
            envelopeCache = (0...steps).map { step in
                exp(-pow((Double(step) / Double(steps) - 0.5) / 0.2, 2))
            }
        }
        return envelopeCache
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
        envelopes: [Double],
        amplitude: CGFloat,
        frame: WaveEngine.Frame,
        appearance: WaveAppearance
    ) -> (ribbon: CGPath, nearGlow: CGPath, wideGlow: CGPath) {
        let steps = envelopes.count - 1
        let limit = Double(rect.height / 2 - 3)
        let time = frame.clock
        let maxHalfWidth = (0.8 + 1.0 * frame.level) * strand.gain
        var points: [CGPoint] = []
        var halfWidths: [CGFloat] = []
        points.reserveCapacity(steps + 1)
        halfWidths.reserveCapacity(steps + 1)

        for (step, envelope) in envelopes.enumerated() {
            let progress = Double(step) / Double(steps)
            // Slowly moving swell so humps rise and fall along the strand.
            let swell = 0.65 + 0.35 * sin(progress * .pi * 1.6 + time * strand.swellSpeed + strand.phase)
            let wave = sin(progress * .pi * 2 * strand.cycles + time * strand.speed + strand.phase)
            // Louder speech adds a faster ripple on top of the main wave.
            let ripple = frame.level * 0.3 * sin(progress * .pi * 2 * strand.cycles * 2.3 - time * strand.speed * 1.7)
            let raw = Double(amplitude) * strand.gain * envelope * swell * (wave + ripple)
            // Soft limit keeps loud peaks inside the frame without flat tops.
            let offset = limit * tanh(raw / limit)

            points.append(CGPoint(x: rect.minX + rect.width * progress, y: rect.midY + offset))
            halfWidths.append(CGFloat((0.3 + maxHalfWidth * envelope) * appearance.lineWidth))
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
                let width = halfWidths[index] + extra * CGFloat(envelopes[index])
                let point = CGPoint(x: points[index].x + normals[index].x * width, y: points[index].y + normals[index].y * width)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            for index in points.indices.reversed() {
                let width = halfWidths[index] + extra * CGFloat(envelopes[index])
                path.addLine(to: CGPoint(x: points[index].x - normals[index].x * width, y: points[index].y - normals[index].y * width))
            }
            path.closeSubpath()
            return path
        }

        return (ribbon(widenedBy: 0), ribbon(widenedBy: 1.5), ribbon(widenedBy: CGFloat(appearance.haloSpread)))
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

    func resume() {
        dismissedAt = nil
    }

    func advance(mode: Mode, audioLevel: Double, at time: TimeInterval) -> Frame {
        let elapsed = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time

        let targetLevel: Double
        switch mode {
        case .listening:
            targetLevel = audioLevel
        case .processing:
            targetLevel = 0.1 + 0.05 * sin(time * 4.4)
        case .pasted:
            targetLevel = 0
            if pastedAt == nil {
                pastedAt = time
            }
        }
        level = Self.ease(level, toward: targetLevel, rate: targetLevel > level ? 35 : 10, elapsed: elapsed)
        // Waves drift twice as fast while processing, so the wait feels short.
        clock += elapsed * (1 + 1.8 * level) * (mode == .processing ? 2 : 1)
        scanAmount = Self.ease(scanAmount, toward: mode == .processing ? 1 : 0, rate: 12, elapsed: elapsed)

        // The orb pops in, then stretches into waves; dismissal reverses it.
        if let dismissedAt {
            spread = Self.ease(spread, toward: 0, rate: 20, elapsed: elapsed)
            let target = time - dismissedAt > 0.12 ? 0.0 : 1.0
            visibility = Self.ease(visibility, toward: target, rate: 26, elapsed: elapsed)
        } else {
            // Kept short: the waves only react to the voice once spread out.
            let target = time - presentedAt > 0.02 ? 1.0 : 0.0
            spread = Self.ease(spread, toward: target, rate: 30, elapsed: elapsed)
            visibility = Self.ease(visibility, toward: 1, rate: 40, elapsed: elapsed)
        }

        return Frame(
            level: level,
            clock: clock,
            spread: spread,
            visibility: visibility,
            flash: pastedAt.map { exp(-(time - $0) * 5) } ?? 0,
            scan: sin(time * 4.8),
            scanAmount: scanAmount
        )
    }

    private static func ease(_ value: Double, toward target: Double, rate: Double, elapsed: Double) -> Double {
        value + (target - value) * (1 - exp(-rate * elapsed))
    }
}

/// Colours of one wave theme: strands alternate between `primary` and
/// `secondary`.
struct WavePalette {
    let primary: CGColor
    let secondary: CGColor
}

extension WaveColor {
    var palette: WavePalette {
        switch self {
        case .blue:
            Self.palette(primary: (0.38, 0.95, 0.96), secondary: (0.34, 0.6, 1.0))
        case .red:
            Self.palette(primary: (1.0, 0.45, 0.4), secondary: (1.0, 0.22, 0.42))
        case .yellow:
            Self.palette(primary: (1.0, 0.88, 0.4), secondary: (1.0, 0.62, 0.22))
        case .green:
            Self.palette(primary: (0.5, 1.0, 0.62), secondary: (0.22, 0.88, 0.72))
        case .violet:
            Self.palette(primary: (0.82, 0.6, 1.0), secondary: (0.56, 0.42, 1.0))
        }
    }

    private static func palette(
        primary: (Double, Double, Double),
        secondary: (Double, Double, Double)
    ) -> WavePalette {
        func color(_ rgb: (Double, Double, Double)) -> CGColor {
            CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
        return WavePalette(primary: color(primary), secondary: color(secondary))
    }
}

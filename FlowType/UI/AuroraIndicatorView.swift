import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Aurora style of the floating indicator: a glass bubble with coloured
/// smoke turning slowly inside it. The voice lights the smoke up, brighter
/// and hotter the louder it is, stirs it faster and swells the bubble,
/// which pulses and wobbles like jelly while it is big. While the text is
/// processed it thinks: smaller, breathing evenly, whirling, in its
/// palette's thinking colours. It appears as its burst played backwards,
/// the smoke gathering out of nothing into a small clot that swells into
/// the bubble; at the end it bursts and the smoke tears apart and
/// dissolves.
///
/// Drawn by AuroraRenderer with Metal: volumetric smoke and the soft glow
/// can't be had from shape layers.
struct AuroraIndicatorView: NSViewRepresentable {
    @ObservedObject var model: FloatingIndicatorModel

    /// A 44 pt sphere plus room to swell by a third with its glow fading out
    /// well inside the frame, and for the smoke drifting off when it bursts;
    /// wide enough for the error pill that replaces it.
    static let size = CGSize(width: 112, height: 112)
    /// Height of the sphere's centre above the Dock; the frame's inset is
    /// derived from it, so resizing the frame leaves the sphere in place.
    static let sphereCenterAboveDock: CGFloat = 32
    /// The burst, from the pop to the last wisp of smoke.
    static let burstDuration: TimeInterval = 0.65
    /// The burst played backwards on appearing, quicker: the smoke gathers
    /// out of nothing into a clot, which then swells into the bubble.
    static let gatherDuration: TimeInterval = 0.25
    /// How far into the burst the gathering starts from: nearly all of the
    /// smoke is gone there, without wasting time on the invisible end.
    static let gatherStart = 0.9
    /// Size of the clot the smoke gathers into, against the bubble.
    static let clotSize = 0.3
    /// The burst plus a little slack: the dismissal reaches the view a
    /// frame after the panel's hide timer starts.
    static let dismissalDuration: TimeInterval = burstDuration + 0.05

    func makeNSView(context: Context) -> AuroraLayerView {
        AuroraLayerView(frame: CGRect(origin: .zero, size: Self.size), model: model)
    }

    func updateNSView(_ view: AuroraLayerView, context: Context) {
        view.apply(model.auroraPalette)
        view.update(
            mode: WaveEngine.Mode(model.content),
            presentationID: model.presentationID,
            isDismissing: model.isDismissing
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AuroraLayerView, context: Context) -> CGSize? {
        Self.size
    }
}

/// One renderer shared by every Aurora view.
private let sharedRenderer: AuroraRenderer? = {
    guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else {
        return nil
    }
    return AuroraRenderer(device: device, library: library)
}()

final class AuroraLayerView: MetalIndicatorLayerView {
    private static let sphereRadius: CGFloat = 22

    /// Voice level with a quick attack and a slow release, so words show at
    /// once and pauses calm down gradually.
    private var level = 0.0
    /// Motion clock. It runs faster while the voice is up, so speech stirs
    /// the smoke and pauses let it settle.
    private var phase = 0.0
    /// Clock of the pulse and the jelly wobble, in seconds.
    private var wobble = 0.0
    /// Size of the bubble apart from the voice: it shrinks into a clot as
    /// the smoke gathers, then a spring swells it to 1 with a little
    /// overshoot.
    private var growth = 1.0
    private var growthVelocity = 0.0
    /// Whether the smoke is still gathering into the clot after appearing.
    private var isGathering = false
    /// How far the voice has swollen the sphere, 0 at rest, about 1 at full
    /// voice, and how fast it changes. A loose spring, so it bounces when
    /// syllables kick it.
    private var swell = 0.0
    private var swellVelocity = 0.0
    /// How far the bubble is burst, 0 whole, 1 popped and the smoke gone.
    /// It runs down as the bubble appears and up as it is dismissed.
    private var burst = 0.0
    /// Drawn anew for every appearance and burst, so no two look the same:
    /// which tongues the smoke splits into, and how it spirals.
    private var burstSeed = 0.0
    private var burstSpin = 0.0
    /// How far the bubble has gone over to thinking while the text is
    /// processed, and how fast it changes: smaller, breathing evenly,
    /// whirling, in the palette's thinking colours. A spring, so it settles
    /// into the smaller size with a little bounce.
    private var thinking = 0.0
    private var thinkingVelocity = 0.0
    /// Turn of the thinking whirl, in radians.
    private var swirl = 0.0

    private var palette: AuroraPalette?
    private var colors = AuroraPalette.nebula.colors

    init(frame frameRect: NSRect, model: FloatingIndicatorModel) {
        super.init(
            frame: frameRect, model: model, style: .aurora,
            device: sharedRenderer?.device, pixelFormat: AuroraRenderer.pixelFormat
        )
    }

    override func didStartPresentation() {
        // Each presentation starts somewhere new in the smoke, and the clock
        // stays small enough for Float precision.
        phase = Double.random(in: 0..<100)
        wobble = 0
        level = 0
        swell = 0
        swellVelocity = 0
        thinking = 0
        thinkingVelocity = 0
        swirl = 0
        growth = 1
        growthVelocity = 0
        isGathering = true
        burst = AuroraIndicatorView.gatherStart
        drawBurstShape()
    }

    override func render(_ frame: WaveEngine.Frame) {
        let voice = frame.voiceLevel
        // About 60 ms to respond when a word starts, 350 ms to settle after
        // it, on top of the engine's own smoothing.
        level = WaveEngine.ease(level, toward: voice, rate: voice > level ? 16 : 3, elapsed: frame.elapsed)
        let energy = Self.energy(level)
        advancePresence(by: frame.elapsed, dismissalAge: frame.dismissalAge)
        // It bursts as it is when dismissed, so a paste right after thinking
        // pops the small thinking bubble.
        if frame.dismissalAge == nil {
            Self.spring(
                &thinking, &thinkingVelocity, toward: frame.scanAmount,
                frequency: 10, damping: 0.55, elapsed: frame.elapsed
            )
        } else {
            thinkingVelocity = 0
        }
        let thought = min(1, max(0, thinking))
        advanceSwirl(by: frame.elapsed, thought: thought, isThinking: frame.scanAmount > 0)
        // While thinking the smoke stays gently lit, a little over half of
        // full light. Squeezed into the clot as it appears, it burns nearly
        // as bright as at full voice.
        let compression = min(1, max(0, 1 - growth) / (1 - AuroraIndicatorView.clotSize))
        let light = max(energy, 0.6 * thought, 0.9 * compression)
        // Up to three and a half times faster at full voice, and faster
        // still while the smoke is loose.
        phase += frame.elapsed * (1 + 2.5 * light + 3 * burst)
        wobble += frame.elapsed

        // The bubble stays swollen while the voice is up and gets a kick on
        // every syllable from the engine's faster level.
        let swellTarget = 0.75 * energy + 0.25 * Self.energy(voice)
        Self.spring(
            &swell, &swellVelocity, toward: swellTarget,
            frequency: 12, damping: 0.3, elapsed: frame.elapsed
        )
        // While swollen it also pulses in and out and wobbles like jelly,
        // more the louder the voice; two rates, so it never looks like a
        // metronome.
        let pulse = 0.05 * energy * (0.65 * sin(2 * .pi * 2.4 * wobble) + 0.35 * sin(2 * .pi * 3.9 * wobble))
        let squash = 0.05 * energy * sin(2 * .pi * 1.7 * wobble + 1)
        // Thinking, it shrinks to three quarters and breathes evenly, about
        // once a second.
        let breath = 1 - 0.25 * thinking + 0.05 * thought * sin(2 * .pi * 1.1 * wobble)

        guard let renderer = sharedRenderer, let drawable = nextDrawable() else { return }

        let radius = Self.sphereRadius * metalLayer.contentsScale * growth * breath * (1 + 0.25 * swell + pulse)
        let uniforms = AuroraRenderer.Uniforms(
            size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            // Never quite zero, the shader divides by it.
            radius: Float(max(radius, 0.5)),
            phase: Float(phase),
            light: Float(light),
            // The engine's faster level runs ahead of ours on syllables and
            // peaks, lifting them for a moment.
            accent: Float(min(1, max(0, voice - level) * 5)),
            flash: Float(frame.flash),
            processing: Float(thought),
            swirl: Float(swirl),
            squash: Float(squash),
            burst: Float(burst),
            burstSeed: Float(burstSeed),
            burstSpin: Float(burstSpin),
            // The glass forms as the clot swells into the bubble, and
            // vanishes in the first moment of the burst, with nothing flying
            // off, so the pop is felt only in the smoke breaking loose.
            glass: Float(Self.smoothstep(0.35, 0.9, growth) * (1 - Self.smoothstep(0, 0.1, burst)))
        )
        renderer.render(uniforms, colors: colors, to: drawable)
    }

    /// The voice level, lifted so ordinary speech (a level of 0.05 to 0.15)
    /// already lights the smoke to between half and most of the way, and
    /// raised speech closes in on full without a hard ceiling.
    private static func energy(_ level: Double) -> Double {
        1 - exp(-12 * level)
    }

    /// 0 below `edge0`, 1 above `edge1`, smooth in between, like Metal's.
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Moves a damped spring towards `target`. Small steps keep it stable at
    /// any frame rate.
    private static func spring(
        _ value: inout Double, _ velocity: inout Double, toward target: Double,
        frequency: Double, damping: Double, elapsed: Double
    ) {
        let steps = max(1, Int((elapsed * 240).rounded(.up)))
        let dt = elapsed / Double(steps)
        for _ in 0..<steps {
            let acceleration = frequency * frequency * (target - value) - 2 * damping * frequency * velocity
            velocity += acceleration * dt
            value += velocity * dt
        }
    }

    /// Appearing, the burst runs backwards while the bubble shrinks, so the
    /// smoke gathers into a clot, which then swells into the bubble.
    /// Dismissed, it bursts at whatever size it has. A dismissal taken back
    /// runs the burst backwards at full size. The shader plays the smoke
    /// from `burst`.
    private func advancePresence(by elapsed: Double, dismissalAge: Double?) {
        if let dismissalAge {
            if burst == 0 {
                drawBurstShape()
            }
            isGathering = false
            growthVelocity = 0
            // Goes on from where it is, but keeps up with the clock, so it
            // is over by the time the panel hides even if frames stall.
            let duration = AuroraIndicatorView.burstDuration
            burst = min(1, max(burst + elapsed / duration, dismissalAge / duration))
            return
        }

        let rate = AuroraIndicatorView.gatherStart / AuroraIndicatorView.gatherDuration
        burst = max(0, burst - elapsed * rate)
        if isGathering {
            // The cloud stays wide at first, then is drawn into the clot
            // faster and faster.
            let left = (burst / AuroraIndicatorView.gatherStart).squareRoot()
            growth = AuroraIndicatorView.clotSize + (1 - AuroraIndicatorView.clotSize) * left
            growthVelocity = 0
            isGathering = burst > 0
        } else {
            // About 0.3 s to swell from the clot, with a little overshoot.
            Self.spring(&growth, &growthVelocity, toward: 1, frequency: 14, damping: 0.5, elapsed: elapsed)
        }
    }

    /// Turns the whirl while thinking. Done thinking, it carries on to the
    /// end of its turn, so every smoke comes back round to its own side.
    private func advanceSwirl(by elapsed: Double, thought: Double, isThinking: Bool) {
        if isThinking {
            swirl += elapsed * 1.8 * thought
        } else if swirl > 0 {
            let turn = 2 * Double.pi
            let end = (swirl / turn).rounded(.up) * turn
            swirl += elapsed * 1.8 * max(thought, 1)
            if swirl >= end {
                swirl = 0
            }
        }
    }

    /// Resolves the palette's colours once, not on every frame.
    func apply(_ palette: AuroraPalette) {
        guard palette != self.palette else { return }
        self.palette = palette
        colors = palette.colors
    }

    private func drawBurstShape() {
        // Kept small: the noise hash loses precision on large arguments.
        burstSeed = Double.random(in: 0..<10)
        burstSpin = Double.random(in: 0.4...0.9) * (Bool.random() ? 1 : -1)
    }
}

/// Colours of the aurora in one state, laid out as AuroraColorSet in
/// AuroraShader.metal: the thin parts of the three smokes (low and front,
/// right, top), their thick parts, then the glass rim round the sides and
/// bottom and along the top. Alpha is unused.
struct AuroraColorSet {
    var dim: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var bright: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var rimSide: SIMD4<Float>
    var rimTop: SIMD4<Float>

    typealias Three = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    init(dim: Three, bright: Three, rimSide: SIMD3<Float>, rimTop: SIMD3<Float>) {
        func rgba(_ color: SIMD3<Float>) -> SIMD4<Float> { SIMD4(color, 1) }
        self.dim = (rgba(dim.0), rgba(dim.1), rgba(dim.2))
        self.bright = (rgba(bright.0), rgba(bright.1), rgba(bright.2))
        self.rimSide = rgba(rimSide)
        self.rimTop = rgba(rimTop)
    }
}

/// A palette's colours while listening and while thinking, laid out as
/// AuroraColors in AuroraShader.metal; the shader blends them.
struct AuroraColors {
    var listening: AuroraColorSet
    var thinking: AuroraColorSet
}

extension AuroraPalette {
    var colors: AuroraColors {
        AuroraColors(listening: listening, thinking: thinking)
    }

    /// Colours while listening.
    private var listening: AuroraColorSet {
        switch self {
        case .nebula:
            AuroraColorSet(
                dim: ([1.0, 0.45, 0.2], [0.5, 0.15, 1.0], [0.15, 0.4, 1.0]),
                bright: ([1.0, 0.8, 0.5], [0.85, 0.55, 1.0], [0.55, 0.8, 1.0]),
                rimSide: [0.7, 0.3, 1.0], rimTop: [0.55, 0.78, 1.0]
            )
        case .ocean:
            AuroraColorSet(
                dim: ([0.05, 0.7, 0.65], [0.1, 0.25, 1.0], [0.2, 0.75, 1.0]),
                bright: ([0.5, 1.0, 0.9], [0.45, 0.65, 1.0], [0.7, 0.95, 1.0]),
                rimSide: [0.15, 0.45, 1.0], rimTop: [0.6, 0.95, 1.0]
            )
        case .ember:
            AuroraColorSet(
                dim: ([1.0, 0.6, 0.1], [1.0, 0.15, 0.15], [1.0, 0.35, 0.1]),
                bright: ([1.0, 0.9, 0.5], [1.0, 0.5, 0.4], [1.0, 0.7, 0.4]),
                rimSide: [1.0, 0.25, 0.2], rimTop: [1.0, 0.75, 0.45]
            )
        case .borealis:
            AuroraColorSet(
                dim: ([0.15, 1.0, 0.45], [0.55, 0.2, 1.0], [0.1, 0.8, 0.8]),
                bright: ([0.6, 1.0, 0.75], [0.85, 0.6, 1.0], [0.55, 1.0, 0.95]),
                rimSide: [0.5, 0.3, 1.0], rimTop: [0.4, 1.0, 0.7]
            )
        }
    }

    /// Colours while the text is processed, set apart from the listening
    /// ones, so thinking reads at a glance.
    private var thinking: AuroraColorSet {
        switch self {
        case .nebula:
            // Cools to turquoise and white.
            AuroraColorSet(
                dim: ([0.1, 0.75, 0.8], [0.3, 0.5, 1.0], [0.6, 0.8, 1.0]),
                bright: ([0.6, 1.0, 0.95], [0.7, 0.85, 1.0], [0.92, 0.97, 1.0]),
                rimSide: [0.3, 0.6, 1.0], rimTop: [0.8, 0.95, 1.0]
            )
        case .ocean:
            // Turns violet and pink.
            AuroraColorSet(
                dim: ([0.6, 0.2, 1.0], [0.9, 0.3, 0.8], [0.5, 0.4, 1.0]),
                bright: ([0.9, 0.6, 1.0], [1.0, 0.65, 0.95], [0.85, 0.8, 1.0]),
                rimSide: [0.7, 0.3, 1.0], rimTop: [0.9, 0.75, 1.0]
            )
        case .ember:
            // Melts into gold.
            AuroraColorSet(
                dim: ([1.0, 0.8, 0.3], [1.0, 0.6, 0.2], [1.0, 0.9, 0.5]),
                bright: ([1.0, 0.97, 0.75], [1.0, 0.88, 0.6], [1.0, 1.0, 0.85]),
                rimSide: [1.0, 0.65, 0.25], rimTop: [1.0, 0.95, 0.7]
            )
        case .borealis:
            // Warms to dawn pink and peach.
            AuroraColorSet(
                dim: ([1.0, 0.45, 0.6], [1.0, 0.6, 0.35], [0.9, 0.4, 0.9]),
                bright: ([1.0, 0.8, 0.85], [1.0, 0.88, 0.7], [1.0, 0.75, 1.0]),
                rimSide: [1.0, 0.4, 0.7], rimTop: [1.0, 0.85, 0.75]
            )
        }
    }

    /// The three smokes' colours, for the palette's swatch in Settings.
    var swatchColors: [Color] {
        let dim = listening.dim
        return [dim.0, dim.1, dim.2].map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }
    }
}

/// Plays a scripted voice level so the smoke at each level can be compared
/// without speaking.
private struct AuroraPreview: View {
    private static let levels: [Double] = [0, 0.03, 0.08, 0.15, 0.3, 0.08, 0]

    @StateObject private var model = FloatingIndicatorModel(content: .status(.recording), style: .aurora)

    var body: some View {
        AuroraIndicatorView(model: model)
            .scaleEffect(4)
            .frame(width: AuroraIndicatorView.size.width * 4, height: AuroraIndicatorView.size.height * 4)
            .padding(40)
            .background(Color(white: 0.12))
            .task {
                while !Task.isCancelled {
                    for level in Self.levels {
                        model.audioLevel = level
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
    }
}

#Preview("Aurora levels") {
    AuroraPreview()
}

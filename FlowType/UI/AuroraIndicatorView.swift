import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Aurora style of the floating indicator: a glass bubble with coloured
/// smoke turning slowly inside it. The voice lights the smoke up, brighter
/// and hotter the louder it is, stirs it faster and swells the bubble,
/// which pulses and wobbles like jelly while it is big. It opens out of a
/// black point; at the end it bursts and the smoke tears apart and
/// dissolves.
///
/// Drawn by AuroraRenderer with Metal: volumetric smoke and the soft glow
/// can't be had from shape layers.
struct AuroraIndicatorView: NSViewRepresentable {
    @ObservedObject var model: FloatingIndicatorModel

    /// A 44 pt sphere plus room to swell by a third, for its glow and for
    /// the smoke drifting off when it bursts; wide enough for the error pill
    /// that replaces it.
    static let size = CGSize(width: 92, height: 88)
    /// The burst, from the pop to the last wisp of smoke.
    static let burstDuration: TimeInterval = 0.65
    /// The burst plus a little slack: the dismissal reaches the view a
    /// frame after the panel's hide timer starts.
    static let dismissalDuration: TimeInterval = burstDuration + 0.05

    func makeNSView(context: Context) -> AuroraLayerView {
        AuroraLayerView(frame: CGRect(origin: .zero, size: Self.size), model: model)
    }

    func updateNSView(_ view: AuroraLayerView, context: Context) {
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
    /// Size of the sphere, 0 a point, 1 full size, and how fast it changes.
    /// It is a spring, so it opens with a little overshoot.
    private var growth = 0.0
    private var growthVelocity = 0.0
    /// How far the voice has swollen the sphere, 0 at rest, about 1 at full
    /// voice, and how fast it changes. A loose spring, so it bounces when
    /// syllables kick it.
    private var swell = 0.0
    private var swellVelocity = 0.0
    /// How lit the sphere is: it opens dark and lights up as it fills out.
    private var glow = 0.0
    /// The dismissal burst, 0 an intact bubble, 1 popped and gone.
    private var burst = 0.0

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
        growth = 0
        growthVelocity = 0
        swell = 0
        swellVelocity = 0
        glow = 0
        burst = 0
    }

    override func render(_ frame: WaveEngine.Frame) {
        let voice = frame.voiceLevel
        // About 60 ms to respond when a word starts, 350 ms to settle after
        // it, on top of the engine's own smoothing.
        level = WaveEngine.ease(level, toward: voice, rate: voice > level ? 16 : 3, elapsed: frame.elapsed)
        let energy = Self.energy(level)
        // While processing the smoke stays gently lit under the sweep, at
        // about a third of full light.
        let light = max(energy, 0.33 * frame.scanAmount)
        // Up to three and a half times faster at full voice, and faster
        // still as the freed smoke drifts off.
        phase += frame.elapsed * (1 + 2.5 * light + 3 * burst)
        wobble += frame.elapsed
        advancePresence(by: frame.elapsed, dismissalAge: frame.dismissalAge)

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

        guard let renderer = sharedRenderer, let drawable = nextDrawable() else { return }

        let radius = Self.sphereRadius * metalLayer.contentsScale * growth * (1 + 0.25 * swell + pulse)
        let uniforms = AuroraRenderer.Uniforms(
            size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            // Never quite zero, the shader divides by it.
            radius: Float(max(radius, 0.5)),
            phase: Float(phase),
            energy: Float(light),
            // The engine's faster level runs ahead of ours on syllables and
            // peaks, lifting them for a moment.
            accent: Float(min(1, max(0, voice - level) * 5)),
            glow: Float(glow),
            flash: Float(frame.flash),
            processing: Float(frame.scanAmount),
            scan: Float(frame.scan),
            squash: Float(squash),
            burst: Float(burst)
        )
        renderer.render(uniforms, to: drawable)
    }

    /// The voice level, lifted so ordinary speech (a level of 0.05 to 0.15)
    /// already lights the smoke to between half and most of the way, and
    /// raised speech closes in on full without a hard ceiling.
    private static func energy(_ level: Double) -> Double {
        1 - exp(-12 * level)
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

    /// Intro: a black point opens into the dark sphere, which lights up as
    /// it fills out. Dismissal: the bubble bursts; the shader plays it from
    /// `burst`. A dismissal taken back mends it quickly.
    private func advancePresence(by elapsed: Double, dismissalAge: Double?) {
        // About 0.35 s to open with a slight overshoot.
        Self.spring(&growth, &growthVelocity, toward: 1, frequency: 13, damping: 0.62, elapsed: elapsed)

        if let dismissalAge {
            // Dismissed again while still mending, it goes on from where it
            // is instead of snapping whole first.
            burst = max(burst, min(1, dismissalAge / AuroraIndicatorView.burstDuration))
        } else {
            // Lights up once the sphere has mostly opened; dismissed before
            // that, it bursts dark.
            if growth > 0.55 {
                glow = WaveEngine.ease(glow, toward: 1, rate: 9, elapsed: elapsed)
            }
            burst = WaveEngine.ease(burst, toward: 0, rate: 14, elapsed: elapsed)
            // Snapped to zero, so the mended bubble has no burst left in it.
            if burst < 0.001 {
                burst = 0
            }
        }
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

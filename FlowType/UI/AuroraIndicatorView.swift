import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Aurora style of the floating indicator: a glass sphere of constant size
/// with coloured smoke turning slowly inside it. The smoke moves on its
/// own; the voice lights it up, brighter and hotter the louder it is. It
/// opens out of a black point and collapses back into one.
///
/// Drawn by AuroraRenderer on a CAMetalLayer: volumetric smoke and the
/// soft glow can't be had from shape layers. Its own small pipeline costs
/// a few drawables, not SwiftUI's Metal renderer.
struct AuroraIndicatorView: NSViewRepresentable {
    @ObservedObject var model: FloatingIndicatorModel

    /// A 44 pt sphere plus room for its glow, wide enough for the error pill
    /// that replaces it.
    static let size = CGSize(width: 72, height: 62)
    /// The light goes out for 0.1 s, then the collapse spring reaches the
    /// point in about 0.19 s; see AuroraLayerView.advancePresence.
    static let dismissalDuration: TimeInterval = 0.32

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

final class AuroraLayerView: IndicatorLayerView {
    private static let sphereRadius: CGFloat = 22

    private let metalLayer = CAMetalLayer()
    /// Voice level with a quick attack and a slow release, so words show at
    /// once and pauses calm down gradually.
    private var level = 0.0
    /// Motion clock. The smoke moves at its own steady pace; the voice only
    /// lights it.
    private var phase = 0.0
    /// Size of the sphere, 0 a point, 1 full size, and how fast it changes.
    /// It is a spring, so it opens with a little overshoot and a collapse
    /// taken back mid-way reverses smoothly.
    private var growth = 0.0
    private var growthVelocity = 0.0
    /// How lit the sphere is: it opens dark and lights up as it fills out,
    /// and goes dark before collapsing.
    private var glow = 0.0

    /// The smoke moves continuously, so it gets the full frame rate; the
    /// renderer is cheap at this size.
    override var frameRateRange: CAFrameRateRange {
        CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    init(frame frameRect: NSRect, model: FloatingIndicatorModel) {
        super.init(frame: frameRect, model: model, style: .aurora)
        setUpLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        updateDrawableSize()
    }

    override func didStartPresentation() {
        // Each presentation starts somewhere new in the smoke, and the clock
        // stays small enough for Float precision.
        phase = Double.random(in: 0..<100)
        level = 0
        growth = 0
        growthVelocity = 0
        glow = 0
    }

    private func setUpLayer() {
        guard let layer, let renderer = sharedRenderer else { return }

        metalLayer.device = renderer.device
        metalLayer.pixelFormat = AuroraRenderer.pixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.frame = bounds
        layer.addSublayer(metalLayer)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func render(_ frame: WaveEngine.Frame) {
        // While processing the smoke stays gently lit under the sweep, at
        // about a third of full light.
        let target = max(frame.level, 0.06 * frame.scanAmount)
        // About 60 ms to respond when a word starts, 350 ms to settle after
        // it, on top of the engine's own smoothing.
        level = WaveEngine.ease(level, toward: target, rate: target > level ? 16 : 3, elapsed: frame.elapsed)
        phase += frame.elapsed
        advancePresence(by: frame.elapsed, dismissalAge: frame.dismissalAge)

        // Once the panel is hidden or covered its drawables aren't returned,
        // and nextDrawable() would block the main thread waiting for one.
        guard window?.occlusionState.contains(.visible) == true else { return }
        guard let renderer = sharedRenderer, let drawable = metalLayer.nextDrawable() else { return }

        let uniforms = AuroraRenderer.Uniforms(
            size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            // Never quite zero, the shader divides by it.
            radius: Float(max(Self.sphereRadius * metalLayer.contentsScale * growth, 0.5)),
            phase: Float(phase),
            level: Float(level),
            // The engine's faster level runs ahead of ours on syllables and
            // peaks, lifting them for a moment.
            accent: Float(min(1, max(0, target - level) * 2.5)),
            glow: Float(glow),
            // The last point fades out instead of vanishing at once.
            visibility: Float(min(1, growth * 20)),
            flash: Float(frame.flash),
            processing: Float(frame.scanAmount),
            scan: Float(frame.scan)
        )
        renderer.render(uniforms, to: drawable)
    }

    /// Intro: a black point opens into the dark sphere, which lights up as
    /// it fills out. Dismissal: the light goes out, then the dark sphere
    /// collapses back into a point.
    private func advancePresence(by elapsed: Double, dismissalAge: Double?) {
        let isDismissing = dismissalAge != nil
        let collapsing = (dismissalAge ?? 0) > 0.1

        // Small steps keep the spring stable at any frame rate.
        let steps = max(1, Int((elapsed * 240).rounded(.up)))
        let dt = elapsed / Double(steps)
        // About 0.35 s to open with a slight overshoot; the collapse
        // starts slowly and speeds up into the point.
        let frequency = collapsing ? 15.0 : 13.0
        let damping = 0.62
        let target = collapsing ? 0.0 : 1.0
        for _ in 0..<steps {
            let acceleration = frequency * frequency * (target - growth) - 2 * damping * frequency * growthVelocity
            growthVelocity += acceleration * dt
            growth += growthVelocity * dt
            if collapsing && growth <= 0 {
                growth = 0
                growthVelocity = 0
            }
        }

        if isDismissing {
            glow = WaveEngine.ease(glow, toward: 0, rate: 22, elapsed: elapsed)
            // Snapped to zero, so the renderer can skip the smoke pass.
            if glow < 0.002 {
                glow = 0
            }
        } else {
            // Lights up once the sphere has mostly opened.
            glow = WaveEngine.ease(glow, toward: growth > 0.55 ? 1 : 0, rate: 9, elapsed: elapsed)
        }
    }
}

/// Plays a scripted voice level so the smoke at each level can be compared
/// without speaking.
private struct AuroraPreview: View {
    private static let levels: [Double] = [0, 0.15, 0.4, 0.75, 1, 0.3, 0]

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

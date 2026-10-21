import AppKit
import Metal
import SwiftUI

/// Particles style of the floating indicator: a field of glowing dots seen
/// in perspective, swelling slowly like a landscape. The voice raises its
/// hills and lights it up; the higher a dot, the brighter and warmer it is,
/// from blue in the hollows to violet and pink on the peaks. Like the waves,
/// it gathers out of the middle and folds back into it.
///
/// Drawn by ParticleFieldRenderer with Metal: thousands of glowing dots
/// can't be had cheaply from shape layers.
struct ParticleFieldIndicatorView: NSViewRepresentable {
    @ObservedObject var model: FloatingIndicatorModel

    /// The field plus room for its glow. As tall as the waves frame, so the
    /// wide styles sit at the same height above the Dock.
    static let size = CGSize(width: 230, height: WaveIndicatorView.size.height)

    func makeNSView(context: Context) -> ParticleFieldLayerView {
        ParticleFieldLayerView(frame: CGRect(origin: .zero, size: Self.size), model: model)
    }

    func updateNSView(_ view: ParticleFieldLayerView, context: Context) {
        view.update(
            mode: WaveEngine.Mode(model.content),
            presentationID: model.presentationID,
            isDismissing: model.isDismissing
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ParticleFieldLayerView, context: Context) -> CGSize? {
        Self.size
    }
}

/// One renderer shared by every Particles view.
private let sharedRenderer: ParticleFieldRenderer? = {
    guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else {
        return nil
    }
    return ParticleFieldRenderer(device: device, library: library)
}()

final class ParticleFieldLayerView: MetalIndicatorLayerView {
    /// Voice level with a quick attack and a slow release, for the light.
    private var level = 0.0
    /// A slower follower of the voice for the hills, so the field rises and
    /// settles smoothly instead of jumping with every syllable.
    private var lift = 0.0
    /// Motion clock for the drifting hill and the twinkle.
    private var phase = 0.0
    /// Clock of the waves. It follows the slow `lift`, so the waves speed up
    /// while speaking and calm down after without ever jumping.
    private var wavePhase = 0.0

    init(frame frameRect: NSRect, model: FloatingIndicatorModel) {
        super.init(
            frame: frameRect, model: model, style: .particles,
            device: sharedRenderer?.device, pixelFormat: ParticleFieldRenderer.pixelFormat
        )
    }

    override func didStartPresentation() {
        // Each presentation starts somewhere new in the swells, and the clock
        // stays small enough for Float precision.
        phase = Double.random(in: 0..<100)
        wavePhase = phase
        level = 0
        lift = 0
    }

    override func render(_ frame: WaveEngine.Frame) {
        // While processing the field stays gently lit under the sweep.
        let target = max(frame.level, 0.06 * frame.scanAmount)
        level = WaveEngine.ease(level, toward: target, rate: target > level ? 16 : 3, elapsed: frame.elapsed)
        // Lifted like the light, so ordinary speech already raises the hills.
        let liftTarget = 1 - exp(-6 * target)
        lift = WaveEngine.ease(lift, toward: liftTarget, rate: liftTarget > lift ? 5 : 1.5, elapsed: frame.elapsed)
        phase += frame.elapsed
        wavePhase += frame.elapsed * (1 + 1.6 * lift)

        guard let renderer = sharedRenderer, let drawable = nextDrawable() else { return }

        let uniforms = ParticleFieldRenderer.Uniforms(
            size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
            scale: Float(metalLayer.contentsScale),
            phase: Float(phase),
            wavePhase: Float(wavePhase),
            level: Float(level),
            lift: Float(lift),
            spread: Float(frame.spread),
            visibility: Float(frame.visibility),
            flash: Float(frame.flash),
            processing: Float(frame.scanAmount),
            scan: Float(frame.scan)
        )
        renderer.render(uniforms, to: drawable)
    }
}

/// Plays a scripted voice level so the field at each level can be compared
/// without speaking.
private struct ParticleFieldPreview: View {
    private static let levels: [Double] = [0, 0.15, 0.4, 0.75, 1, 0.3, 0]

    @StateObject private var model = FloatingIndicatorModel(content: .status(.recording), style: .particles)

    var body: some View {
        ParticleFieldIndicatorView(model: model)
            .scaleEffect(2)
            .frame(width: ParticleFieldIndicatorView.size.width * 2, height: ParticleFieldIndicatorView.size.height * 2)
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

#Preview("Particles levels") {
    ParticleFieldPreview()
}

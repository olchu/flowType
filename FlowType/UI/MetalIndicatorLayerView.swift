import AppKit
import Metal
import QuartzCore

/// Where a Metal style draws its next frame: a drawable shown on screen, or
/// IndicatorRecorder's texture.
struct IndicatorRenderTarget {
    let texture: MTLTexture
    let drawable: CAMetalDrawable?

    /// Commits the frame's commands: presents the drawable, or without one
    /// waits for the frame, so a recording can read it back.
    func commit(_ commands: MTLCommandBuffer) {
        guard let drawable else {
            commands.commit()
            commands.waitUntilCompleted()
            return
        }
        commands.present(drawable)
        commands.commit()
    }
}

/// Shared base of the indicator styles drawn with Metal: hosts a
/// CAMetalLayer the size of the view at the screen's scale and hands out its
/// drawables. Its own small pipeline costs a few drawables, not SwiftUI's
/// Metal renderer.
class MetalIndicatorLayerView: IndicatorLayerView {
    let metalLayer = CAMetalLayer()

    /// Metal styles move continuously, so they get the full frame rate;
    /// their renderers are cheap at this size.
    override var frameRateRange: CAFrameRateRange {
        CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    init(frame frameRect: NSRect, model: FloatingIndicatorModel, style: IndicatorStyle, device: MTLDevice?, pixelFormat: MTLPixelFormat) {
        super.init(frame: frameRect, model: model, style: style)
        guard let layer, let device else { return }

        metalLayer.device = device
        metalLayer.pixelFormat = pixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.frame = bounds
        layer.addSublayer(metalLayer)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        updateDrawableSize()
    }

    /// Set by IndicatorRecorder: frames are drawn into it instead of onto
    /// the screen.
    private var recordingTarget: MTLTexture?

    /// Draws every following frame into `texture`, at its size.
    func record(into texture: MTLTexture) {
        recordingTarget = texture
        metalLayer.contentsScale = CGFloat(texture.width) / bounds.width
        updateDrawableSize()
    }

    /// Where to draw the next frame, or nil while the panel is hidden or
    /// covered: then its drawables aren't returned, and nextDrawable() would
    /// block the main thread waiting for one.
    func nextTarget() -> IndicatorRenderTarget? {
        if let recordingTarget {
            return IndicatorRenderTarget(texture: recordingTarget, drawable: nil)
        }
        guard window?.occlusionState.contains(.visible) == true, let drawable = metalLayer.nextDrawable() else {
            return nil
        }
        return IndicatorRenderTarget(texture: drawable.texture, drawable: drawable)
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

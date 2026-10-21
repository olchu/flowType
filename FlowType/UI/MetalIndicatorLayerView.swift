import AppKit
import Metal
import QuartzCore

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

    /// The next drawable, or nil while the panel is hidden or covered: then
    /// its drawables aren't returned, and nextDrawable() would block the main
    /// thread waiting for one.
    func nextDrawable() -> CAMetalDrawable? {
        guard window?.occlusionState.contains(.visible) == true else { return nil }
        return metalLayer.nextDrawable()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

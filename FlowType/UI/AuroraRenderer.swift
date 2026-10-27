import Metal
import QuartzCore

/// Draws the Aurora sphere with the pipelines in AuroraShader.metal.
final class AuroraRenderer {
    /// Must match AuroraUniforms in AuroraShader.metal.
    struct Uniforms {
        var size: SIMD2<Float>
        var radius: Float
        var phase: Float
        var energy: Float
        var accent: Float
        var flash: Float
        var processing: Float
        var scan: Float
        var squash: Float
        var burst: Float
        var burstSeed: Float
        var burstSpin: Float
        var glass: Float
    }

    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// The smoke and the glass add their light together in this format, in
    /// more than 8 bits, before the output pass tone-maps it.
    private static let lightFormat = MTLPixelFormat.rgba16Float

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let glassPipeline: MTLRenderPipelineState
    private let smokePipeline: MTLRenderPipelineState
    private let outputPipeline: MTLRenderPipelineState
    /// Light textures by drawable size, so views at different scales (the
    /// indicator and the settings preview) don't take turns reallocating
    /// one. Their mipmaps are the blurred light for the glow.
    private var lightTextures: [SIMD2<Int>: MTLTexture] = [:]

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let queue = device.makeCommandQueue() else { return nil }

        /// Every pass is a full-screen quad; the light passes add up.
        func pipeline(fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "auroraFullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if format == Self.lightFormat {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard
            let glass = pipeline(fragment: "auroraGlassFragment", format: Self.lightFormat),
            let smoke = pipeline(fragment: "auroraSmokeFragment", format: Self.lightFormat),
            let output = pipeline(fragment: "auroraOutputFragment", format: Self.pixelFormat)
        else {
            return nil
        }

        self.device = device
        self.queue = queue
        glassPipeline = glass
        smokePipeline = smoke
        outputPipeline = output
    }

    /// Renders one frame into `drawable`, which must be in `pixelFormat` and
    /// of the size in `uniforms`, and presents it.
    func render(_ uniforms: Uniforms, to drawable: CAMetalDrawable) {
        let target = drawable.texture
        guard let light = lightTexture(width: target.width, height: target.height),
              let commands = queue.makeCommandBuffer()
        else {
            return
        }
        var uniforms = uniforms

        let lightPass = MTLRenderPassDescriptor()
        lightPass.colorAttachments[0].texture = light
        lightPass.colorAttachments[0].loadAction = .clear
        lightPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        lightPass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: lightPass) {
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setRenderPipelineState(glassPipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // Once the burst is over there is no smoke to draw.
            if uniforms.burst < 1 {
                encoder.setRenderPipelineState(smokePipeline)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        }
        // The output pass reads the glow from the blurred mipmap levels.
        if let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: light)
            blit.endEncoding()
        }

        let outputPass = MTLRenderPassDescriptor()
        outputPass.colorAttachments[0].texture = target
        // The output pass writes every pixel.
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: outputPass) {
            encoder.setRenderPipelineState(outputPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(light, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        commands.present(drawable)
        commands.commit()
    }

    private func lightTexture(width: Int, height: Int) -> MTLTexture? {
        let key = SIMD2(width, height)
        if let texture = lightTextures[key] {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.lightFormat, width: width, height: height, mipmapped: true)
        // The glow reads only the first few levels; see auroraOutputFragment.
        descriptor.mipmapLevelCount = min(descriptor.mipmapLevelCount, 4)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        lightTextures[key] = texture
        return texture
    }
}

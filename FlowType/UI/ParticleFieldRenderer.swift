import Metal
import QuartzCore

/// Draws the Particles field with the pipelines in ParticleFieldShader.metal.
final class ParticleFieldRenderer {
    /// Must match ParticleUniforms in ParticleFieldShader.metal.
    struct Uniforms {
        var size: SIMD2<Float>
        var scale: Float
        var phase: Float
        var wavePhase: Float
        var level: Float
        var lift: Float
        var spread: Float
        var visibility: Float
        var flash: Float
        var processing: Float
        var scan: Float
    }

    /// Must match columns and rows in the shader.
    private static let particleCount = 110 * 34
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// The dots add their light together in this format, in more than 8
    /// bits, before the output pass tone-maps it.
    private static let lightFormat = MTLPixelFormat.rgba16Float

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let particlePipeline: MTLRenderPipelineState
    private let outputPipeline: MTLRenderPipelineState
    /// Light textures by drawable size, so views at different scales (the
    /// indicator and the settings preview) don't take turns reallocating
    /// one. Their mipmaps are the blurred light for the glow.
    private var lightTextures: [SIMD2<Int>: MTLTexture] = [:]

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let queue = device.makeCommandQueue() else { return nil }

        let particles = MTLRenderPipelineDescriptor()
        particles.vertexFunction = library.makeFunction(name: "particleVertex")
        particles.fragmentFunction = library.makeFunction(name: "particleFragment")
        let attachment = particles.colorAttachments[0]!
        attachment.pixelFormat = Self.lightFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one

        let output = MTLRenderPipelineDescriptor()
        output.vertexFunction = library.makeFunction(name: "particleFullscreenVertex")
        output.fragmentFunction = library.makeFunction(name: "particleOutputFragment")
        output.colorAttachments[0].pixelFormat = Self.pixelFormat

        guard
            let particlePipeline = try? device.makeRenderPipelineState(descriptor: particles),
            let outputPipeline = try? device.makeRenderPipelineState(descriptor: output)
        else {
            return nil
        }

        self.device = device
        self.queue = queue
        self.particlePipeline = particlePipeline
        self.outputPipeline = outputPipeline
    }

    /// Renders one frame into `drawable`, which must be in `pixelFormat` and
    /// of the size in `uniforms`, and presents it.
    /// `bands` raise the field's mountains, lowest frequency first.
    func render(_ uniforms: Uniforms, bands: SpectrumBands, to drawable: CAMetalDrawable) {
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
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            var bands = bands
            encoder.setVertexBytes(&bands, length: MemoryLayout<SpectrumBands>.size, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Self.particleCount)
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
        // The glow reads only the first few levels; see particleOutputFragment.
        descriptor.mipmapLevelCount = min(descriptor.mipmapLevelCount, 4)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        lightTextures[key] = texture
        return texture
    }
}

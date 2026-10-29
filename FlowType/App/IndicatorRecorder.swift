import AppKit
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

/// Records the indicator off screen for the README's animations, for
/// `--record-indicator`: plays one dictation with DemoVoice at fixed steps
/// of time and writes every frame as a PNG, with the timeline in
/// recording.json for scripts/readme_images.py. See
/// scripts/record_indicators.sh.
@MainActor
enum IndicatorRecorder {
    enum Failure: LocalizedError {
        case unknownStyle(String)
        case unsupported(IndicatorStyle)
        case noMetal
        case cannotWrite(URL)

        var errorDescription: String? {
            switch self {
            case .unknownStyle(let name):
                "There is no \(name) indicator; the styles are \(IndicatorStyle.allCases.map(\.rawValue).formatted())."
            case .unsupported(let style):
                "The \(style.rawValue) indicator is drawn by SwiftUI and can't be recorded."
            case .noMetal:
                "Metal isn't available."
            case .cannotWrite(let url):
                "Could not write \(url.path)."
            }
        }
    }

    /// What scripts/readme_images.py needs to lay the frames out: when each
    /// step starts, and the background to give the tiles.
    private struct Timeline: Encodable {
        var framesPerSecond: Double
        var processingStart: Double
        var pasteTime: Double
        var background: [Int]
    }

    private static let framesPerSecond = 30.0
    /// The dictation, in seconds from the start: speaking, then processing,
    /// then the paste and the dismissal it starts.
    private static let processingStart = 3.2
    private static let pasteTime = 4.6
    /// A moment of nothing after the dismissal, so the loop doesn't restart
    /// straight away.
    private static let trailingPause = 0.4

    /// Writes the frames to `directory` as frame-0000.png and on, `scale`
    /// pixels per point over `background`, and returns how many there are.
    /// `color` is a WaveColor or AuroraPalette raw value, for the styles
    /// that have one.
    static func record(
        _ styleName: String, color: String?, scale: Int, background: CGColor, to directory: URL
    ) throws -> Int {
        guard let style = IndicatorStyle(rawValue: styleName) else { throw Failure.unknownStyle(styleName) }
        let model = FloatingIndicatorModel(content: .status(.recording), style: style)
        let bounds = CGRect(origin: .zero, size: style.indicatorSize)
        let view: IndicatorLayerView
        switch style {
        case .bars:
            throw Failure.unsupported(style)
        case .waves:
            let waves = WaveLayerView(frame: bounds, model: model)
            waves.apply(color.flatMap(WaveColor.init(rawValue:)) ?? .blue)
            view = waves
        case .dots:
            let dots = DotsLayerView(frame: bounds, model: model)
            dots.apply(color.flatMap(WaveColor.init(rawValue:)) ?? .blue)
            view = dots
        case .aurora:
            let aurora = AuroraLayerView(frame: bounds, model: model)
            aurora.apply(color.flatMap(AuroraPalette.init(rawValue:)) ?? .nebula)
            view = aurora
        case .particles:
            view = ParticleFieldLayerView(frame: bounds, model: model)
        }

        // A Metal style has no device when its renderer couldn't be built,
        // and would draw nothing.
        let metalView = view as? MetalIndicatorLayerView
        guard let device = metalView != nil ? metalView?.metalLayer.device : MTLCreateSystemDefaultDevice() else {
            throw Failure.noMetal
        }
        let width = Int(bounds.width) * scale
        let height = Int(bounds.height) * scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.noMetal }

        // Metal styles draw straight into the texture; the shape layer styles
        // are composited into it by Core Animation, at the recording's scale.
        let drawLayers: (() -> Void)?
        if let metalView {
            metalView.record(into: texture)
            drawLayers = nil
        } else {
            guard let queue = device.makeCommandQueue() else { throw Failure.noMetal }
            // Every IndicatorLayerView is layer-backed.
            let layer = view.layer!
            let host = CALayer()
            host.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            host.sublayerTransform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
            layer.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
            host.addSublayer(layer)
            setContentsScale(CGFloat(scale), of: host)

            let renderer = CARenderer(mtlTexture: texture, options: [
                kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                kCARendererMetalCommandQueue: queue,
            ])
            renderer.layer = host
            renderer.bounds = host.bounds
            drawLayers = {
                CATransaction.flush()
                clear(texture, on: queue)
                renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
                renderer.addUpdate(renderer.bounds)
                renderer.render()
                renderer.endFrame()
                // The queue runs in order, so this waits for the render too.
                let commands = queue.makeCommandBuffer()
                commands?.commit()
                commands?.waitUntilCompleted()
            }
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rgb = background.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
            .components?.prefix(3).map { Int(($0 * 255).rounded()) } ?? [0, 0, 0]
        let timeline = Timeline(
            framesPerSecond: framesPerSecond, processingStart: processingStart, pasteTime: pasteTime, background: rgb
        )
        try JSONEncoder().encode(timeline).write(to: directory.appending(path: "recording.json"))

        let dismissTime = pasteTime + style.pastedHoldDuration / .seconds(1)
        let endTime = dismissTime + style.dismissalDuration + trailingPause
        let frameCount = Int((endTime * framesPerSecond).rounded(.up))
        // The engine's clock starts well above zero, as the display's does.
        let start: CFTimeInterval = 1000

        for index in 0..<frameCount {
            let elapsed = Double(index) / framesPerSecond
            let mode: WaveEngine.Mode = elapsed < processingStart ? .listening : elapsed < pasteTime ? .processing : .pasted
            let voice = mode == .listening ? DemoVoice.sample(at: elapsed) : (level: 0, bands: .zero)
            model.audioLevel = voice.level
            model.audioBands = voice.bands
            view.update(mode: mode, presentationID: 1, isDismissing: elapsed >= dismissTime, at: start + elapsed)
            view.drawFrame(at: start + elapsed)
            drawLayers?()

            let url = directory.appending(path: String(format: "frame-%04d.png", index))
            try writePNG(texture, over: background, to: url)
        }
        return frameCount
    }

    private static func setContentsScale(_ scale: CGFloat, of layer: CALayer) {
        layer.contentsScale = scale
        if let mask = layer.mask {
            setContentsScale(scale, of: mask)
        }
        for sublayer in layer.sublayers ?? [] {
            setContentsScale(scale, of: sublayer)
        }
    }

    /// Core Animation draws over what the texture holds, so every frame
    /// starts from transparent.
    private static func clear(_ texture: MTLTexture, on queue: MTLCommandQueue) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else {
            return
        }
        encoder.endEncoding()
        commands.commit()
    }

    /// The texture holds premultiplied BGRA, as a CAMetalLayer shows it. Its
    /// added light can be brighter than its alpha, which a transparent PNG
    /// can't hold, so it is laid over the background the way the window
    /// server lays it over the desktop.
    private static func writePNG(_ texture: MTLTexture, over background: CGColor, to url: URL) throws {
        let bytesPerRow = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let frame = CGImage(
                width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ),
            let context = CGContext(
                data: nil, width: texture.width, height: texture.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo
            )
        else {
            throw Failure.cannotWrite(url)
        }
        let rect = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        context.setFillColor(background)
        context.fill(rect)
        context.draw(frame, in: rect)

        guard
            let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw Failure.cannotWrite(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotWrite(url) }
    }
}

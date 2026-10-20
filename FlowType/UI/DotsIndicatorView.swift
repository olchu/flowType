import AppKit
import SwiftUI

/// Dots style of the floating indicator: columns of dots mirrored around a
/// centre row, tallest in the middle and bouncing with the voice, a bump of
/// light sweeping across while processing, and a flash on paste.
///
/// Drawn with Core Animation layers for the same reason as the waves: a
/// SwiftUI Canvas would start the Metal renderer and its GPU memory.
struct DotsIndicatorView: NSViewRepresentable {
    @ObservedObject var model: FloatingIndicatorModel

    /// 150x80 dots plus room for the glow. As tall as the waves frame, so
    /// both styles sit at the same height above the Dock.
    static let size = CGSize(width: 190, height: WaveIndicatorView.size.height)

    func makeNSView(context: Context) -> DotsLayerView {
        DotsLayerView(frame: CGRect(origin: .zero, size: Self.size), model: model)
    }

    func updateNSView(_ view: DotsLayerView, context: Context) {
        view.update(
            mode: WaveEngine.Mode(model.content),
            presentationID: model.presentationID,
            isDismissing: model.isDismissing
        )
        view.apply(model.waveColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotsLayerView, context: Context) -> CGSize? {
        Self.size
    }
}

final class DotsLayerView: IndicatorLayerView {
    private struct Column {
        /// 0 is the left end, 1 the right end.
        let position: Double
        /// 0 in the middle, 1 at either end.
        let distance: Double
        /// 1 in the middle, falling off towards the ends.
        let closeness: Double
        let speed: Double
        let phase: Double
    }

    private static let glowMargin = CGSize(width: 20, height: 18)
    private static let columnCount = 23
    /// Dots above and below the centre row at full height.
    private static let maxDots = 8
    private static let dotSize = CGSize(width: 2.4, height: 3.1)

    private static let columns: [Column] = (0..<columnCount).map { index in
        let position = Double(index) / Double(columnCount - 1)
        let distance = abs(position - 0.5) * 2
        // A fixed scatter rather than random values, so the bounce looks
        // the same every time.
        return Column(
            position: position,
            distance: distance,
            closeness: exp(-pow(distance / 0.4, 2)),
            speed: 3.2 + Double(index * 37 % 11) * 0.42,
            phase: Double(index * 53 % 17) * 0.37
        )
    }

    private let columnsLayer = CALayer()
    private let fadeMask = CAGradientLayer()
    private let hazeLayer = CAGradientLayer()
    private var columnLayers: [CAShapeLayer] = []
    /// Eased column heights in 0...1: they jump up with the voice and fall
    /// back slowly, like a level meter.
    private var heights = Array(repeating: 0.0, count: columnCount)
    /// Height and scale each column's path was last built for.
    private var drawnGeometry: [(height: Double, scale: Double)?] = Array(repeating: nil, count: columnCount)
    /// Theme colour per column, from the ends towards the middle, before the
    /// white mix.
    private var columnTints: [CGColor] = []
    private var isFlashing = false
    private var waveColor: WaveColor?

    init(frame frameRect: NSRect, model: FloatingIndicatorModel) {
        super.init(frame: frameRect, model: model, style: .dots)
        setUpLayers()
    }

    func apply(_ waveColor: WaveColor) {
        guard waveColor != self.waveColor else { return }
        self.waveColor = waveColor

        let palette = waveColor.palette
        columnTints = Self.columns.map { palette.secondary.mixed(with: palette.primary, amount: $0.closeness) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        applyColumnColors(flash: 0)
        hazeLayer.colors = [
            palette.primary.mixedWithWhite(0.7).copy(alpha: 0.6)!,
            palette.primary.copy(alpha: 0.22)!,
            palette.primary.copy(alpha: 0)!,
        ]
    }

    override func didStartPresentation() {
        heights = Array(repeating: 0, count: Self.columnCount)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [columnsLayer, fadeMask, hazeLayer] + columnLayers {
            layer.contentsScale = scale
        }
    }

    private func setUpLayers() {
        guard let layer else { return }

        hazeLayer.type = .radial
        hazeLayer.locations = [0, 0.4, 1]
        hazeLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        hazeLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(hazeLayer)

        columnsLayer.frame = bounds
        columnsLayer.mask = fadeMask
        layer.addSublayer(columnsLayer)

        // Dims the dots towards the ends and the top and bottom.
        fadeMask.type = .radial
        fadeMask.frame = bounds
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 1)
        fadeMask.locations = [0, 0.45, 0.85, 1]
        fadeMask.colors = [1.0, 0.9, 0.3, 0].map { CGColor(gray: 0, alpha: $0) }

        columnLayers = Self.columns.map { _ in
            let column = CAShapeLayer()
            column.frame = bounds
            column.shadowOffset = .zero
            column.shadowRadius = 2.5
            column.shadowOpacity = 0.9
            // Neighbouring glows add up, so the middle lights up.
            column.compositingFilter = "plusL"
            columnsLayer.addSublayer(column)
            return column
        }

        apply(.blue)
        render(.hidden)
    }

    /// Theme colour at the ends, turning white towards the middle; the paste
    /// flash whitens every column further.
    private func applyColumnColors(flash: Double) {
        for (index, column) in Self.columns.enumerated() {
            let whiteness = min(1, 0.7 * column.closeness * column.closeness + flash)
            let color = columnTints[index].mixedWithWhite(whiteness)
            columnLayers[index].fillColor = color
            columnLayers[index].shadowColor = color
        }
    }

    override func render(_ frame: WaveEngine.Frame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Dots live in the inner rect; the margin is room for the glow.
        let rect = bounds.insetBy(dx: Self.glowMargin.width, dy: Self.glowMargin.height)
        let step = rect.height / 2 / CGFloat(Self.maxDots)

        // The centre row alone gets bright when silent, so dim it until speech.
        let brightness = (0.5 + 0.5 * min(1, frame.level * 2.5) + frame.flash) * frame.visibility
        columnsLayer.opacity = Float(min(1, brightness))

        // Colours only change during the paste flash, plus once after it.
        // Below this the flash no longer shows.
        let flashes = frame.flash > 0.02
        if flashes || isFlashing {
            applyColumnColors(flash: flashes ? frame.flash : 0)
            isFlashing = flashes
        }

        for (index, column) in Self.columns.enumerated() {
            // Columns appear from the middle outwards and fold back in.
            let reveal = min(1, max(0, (frame.spread * 1.15 - column.distance) / 0.15))
            let target = Self.targetHeight(for: column, frame: frame) * reveal
            heights[index] = WaveEngine.ease(
                heights[index],
                toward: target,
                rate: target > heights[index] ? 30 : 9,
                elapsed: frame.elapsed
            )

            let layer = columnLayers[index]
            layer.isHidden = reveal <= 0
            guard reveal > 0 else { continue }

            // Easing never lands exactly, so settled columns are compared
            // with a tolerance before their path is rebuilt.
            let scale = reveal * (0.75 + 0.25 * column.closeness)
            if let drawn = drawnGeometry[index],
               abs(drawn.height - heights[index]) < 0.001,
               abs(drawn.scale - scale) < 0.001 {
                continue
            }
            drawnGeometry[index] = (heights[index], scale)

            let path = Self.columnPath(
                x: rect.minX + rect.width * CGFloat(column.position),
                centerY: rect.midY,
                step: step,
                height: heights[index],
                scale: CGFloat(scale)
            )
            layer.path = path
            layer.shadowPath = path
        }

        let glow = 0.3 + 0.7 * min(1, frame.level * 1.8) + frame.flash
        hazeLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: rect.width * (0.45 + 0.25 * frame.level) * frame.spread,
            height: rect.height * (0.8 + 0.4 * frame.level)
        )
        hazeLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        hazeLayer.opacity = Float(min(1, 0.75 * glow * frame.visibility))
    }

    private static func targetHeight(for column: Column, frame: WaveEngine.Frame) -> Double {
        let time = frame.clock

        // Speech: tallest in the middle, humps running outwards, and every
        // column bouncing on its own, so neighbours differ like a spectrum.
        let bell = exp(-pow(column.distance / 0.5, 2))
        let travel = 0.5 + 0.5 * sin(column.distance * .pi * 3.4 - time * 3.3)
        let bounce = pow(0.5 + 0.5 * sin(time * column.speed + column.phase), 1.5)
        let flicker = 0.5 + 0.5 * sin(time * column.speed * 0.37 + column.phase * 2.1)
        let shape = 0.15 + 0.3 * travel + 0.4 * bounce + 0.15 * flicker
        let speech = min(1, pow(frame.level, 0.8) * 1.45 * bell * shape)

        // Processing: a low line with a bump sweeping back and forth.
        let sweepCenter = 0.5 + 0.42 * frame.scan
        let processing = 0.1 + 0.4 * exp(-pow((column.position - sweepCenter) / 0.09, 2))

        return speech + (processing - speech) * frame.scanAmount
    }

    private static func columnPath(
        x: CGFloat,
        centerY: CGFloat,
        step: CGFloat,
        height: Double,
        scale: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let dots = height * Double(maxDots)

        func addDot(atY y: CGFloat, size: CGFloat) {
            let width = dotSize.width * size
            let height = dotSize.height * size
            path.addEllipse(in: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height))
        }

        addDot(atY: centerY, size: scale)
        for row in 1...maxDots where Double(row - 1) < dots {
            // Smaller towards the top and bottom. The outermost dot grows in
            // as the column rises, so heights change smoothly instead of a
            // dot at a time.
            let grow = CGFloat(min(1, dots - Double(row - 1)))
            let size = (1 - 0.45 * CGFloat(row) / CGFloat(maxDots)) * grow * scale
            guard dotSize.width * size > 0.2 else { continue }

            addDot(atY: centerY + CGFloat(row) * step, size: size)
            addDot(atY: centerY - CGFloat(row) * step, size: size)
        }

        return path
    }
}

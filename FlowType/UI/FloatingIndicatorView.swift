import Combine
import SwiftUI

@MainActor
final class FloatingIndicatorModel: ObservableObject {
    enum Content: Equatable {
        case loading
        case pasted
        case status(AppStatus)
    }

    @Published private(set) var content: Content
    /// Level after the microphone sensitivity gate; 0 means silence.
    @Published private(set) var audioLevel: Double
    @Published private(set) var style: IndicatorStyle
    @Published private(set) var presentationID = 0
    @Published private(set) var dismissalID = 0

    init(content: Content = .status(.ready), audioLevel: Double = 0, style: IndicatorStyle = .bars) {
        self.content = content
        self.audioLevel = audioLevel
        self.style = style
    }

    func show(_ content: Content, audioLevel: Double, style: IndicatorStyle, startsNewPresentation: Bool) {
        // Called at audio level rate; unchanged values must not redraw.
        if self.content != content {
            self.content = content
        }
        if self.audioLevel != audioLevel {
            self.audioLevel = audioLevel
        }
        if self.style != style {
            self.style = style
        }

        if startsNewPresentation {
            presentationID += 1
        }
    }

    func beginDismissal() {
        dismissalID += 1
    }
}

struct FloatingIndicatorView: View {
    @ObservedObject var model: FloatingIndicatorModel

    @State private var isExpanded = false
    @State private var showsContent = false
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        let size = model.style.indicatorSize

        ZStack {
            // Waves float on a transparent background and run their own
            // intro and dismissal; errors still use the pill.
            if model.style == .waves && model.content != .status(.error) {
                WaveIndicatorView(model: model)
            } else {
                Capsule()
                    .fill(.black)
                    .frame(width: isExpanded ? 72 : 8, height: isExpanded ? 20 : 8)

                content
                    .foregroundStyle(.white)
                    .opacity(showsContent ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear(perform: runIntroAnimation)
        .onChange(of: model.presentationID) {
            runIntroAnimation()
        }
        .onChange(of: model.dismissalID) {
            runDismissalAnimation()
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 12) {
            switch model.content {
            case .loading:
                LoadingStatusView()
            case .pasted:
                PastedStatusView()
            case .status(.recording):
                RecordingBarsView(audioLevel: model.audioLevel)
            case .status(.transcribing):
                TranscribingDotsView()
            case .status(.ready):
                EmptyView()
            case .status(.error):
                StatusTextView(text: "Error")
            }
        }
        .frame(minWidth: 54, minHeight: 14)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
    }

    private func runIntroAnimation() {
        animationTask?.cancel()
        showsContent = false
        isExpanded = false

        withAnimation(.easeOut(duration: 0.18)) {
            isExpanded = true
        }

        animationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                showsContent = true
            }
        }
    }

    private func runDismissalAnimation() {
        animationTask?.cancel()

        withAnimation(.easeIn(duration: 0.08)) {
            showsContent = false
        }

        animationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.12)) {
                isExpanded = false
            }
        }
    }
}

private struct RecordingBarsView: View {
    let audioLevel: Double

    private let bars = Array(0..<8)
    private static let speeds: [Double] = [7.6, 4.9, 8.8, 5.7, 9.4, 6.5, 8.1, 5.2]
    private static let phases: [Double] = [0.1, 1.7, 3.4, 0.8, 2.6, 4.1, 1.2, 3.0]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2) {
                ForEach(bars, id: \.self) { index in
                    Capsule()
                        .frame(width: 2, height: height(for: index, time: time))
                        .opacity(opacity(for: index, time: time))
                }
            }
            .frame(width: 30, height: 12)
        }
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        guard audioLevel > 0 else { return 4 }

        let speed = Self.speeds[index]
        let phase = Self.phases[index]
        let beat = abs(sin(time * speed + phase))
        let flicker = abs(sin(time * speed * 0.43 + phase * 1.8))
        let level = min(1, (beat * 0.72 + flicker * 0.42) * (0.35 + audioLevel * 1.15))
        return 3 + CGFloat(level) * 9
    }

    private func opacity(for index: Int, time: TimeInterval) -> Double {
        guard audioLevel > 0 else { return 0.38 }

        let phase = time * (6.0 + Double(index).truncatingRemainder(dividingBy: 3)) + Double(index)
        let normalized = abs(sin(phase))
        return 0.5 + normalized * 0.5
    }
}

/// Waves style. One Canvas draws everything: a glowing orb that stretches
/// into waves on appear, live strands while recording, a calm scanning line
/// while processing, and the collapse back into the orb on dismissal.
/// Strands are vector paths; the glow is wide faint strokes under a thin
/// bright one, which is much cheaper than a blur filter.
private struct WaveIndicatorView: View {
    @ObservedObject var model: FloatingIndicatorModel

    @State private var engine = WaveEngine()
    @State private var isPaused = false
    @State private var pauseTask: Task<Void, Never>?

    private struct Strand {
        let cycles: Double
        let speed: Double
        let phase: Double
        let swellSpeed: Double
        let gain: Double
        let isCyan: Bool
    }

    // Opposite speeds make strands drift through each other.
    private static let strands: [Strand] = [
        Strand(cycles: 1.6, speed: 3.1, phase: 0.0, swellSpeed: 1.3, gain: 1.0, isCyan: true),
        Strand(cycles: 2.1, speed: -2.4, phase: 1.9, swellSpeed: -0.9, gain: 0.85, isCyan: false),
        Strand(cycles: 1.2, speed: 2.0, phase: 3.6, swellSpeed: 0.7, gain: 0.7, isCyan: true),
        Strand(cycles: 2.6, speed: -3.4, phase: 5.0, swellSpeed: 1.1, gain: 0.55, isCyan: false),
        Strand(cycles: 1.9, speed: 4.2, phase: 2.4, swellSpeed: -1.5, gain: 0.4, isCyan: true),
    ]

    private static let glowMargin = CGSize(width: 20, height: 18)
    private static let cyan = Color(red: 0.38, green: 0.95, blue: 0.96)
    private static let blue = Color(red: 0.34, green: 0.6, blue: 1.0)
    private static let cyanGradient = fadingGradient(cyan)
    private static let blueGradient = fadingGradient(blue)
    private static let orbGradient = Gradient(stops: [
        .init(color: .white, location: 0),
        .init(color: .white, location: 0.12),
        .init(color: cyan, location: 0.3),
        .init(color: cyan.opacity(0.3), location: 0.55),
        .init(color: cyan.opacity(0), location: 1),
    ])
    private static let scanGradient = Gradient(colors: [cyan.opacity(0.55), cyan.opacity(0)])

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isPaused)) { timeline in
            let frame = engine.advance(
                mode: mode,
                audioLevel: model.audioLevel,
                at: timeline.date.timeIntervalSinceReferenceDate
            )

            Canvas { context, size in
                Self.draw(frame, in: &context, size: size)
            }
        }
        .frame(
            width: 240 + Self.glowMargin.width * 2,
            height: 80 + Self.glowMargin.height * 2
        )
        .onAppear(perform: present)
        .onChange(of: model.presentationID) {
            present()
        }
        .onChange(of: model.dismissalID) {
            dismiss()
        }
    }

    private var mode: WaveEngine.Mode {
        switch model.content {
        case .status(.recording):
            .listening
        case .pasted:
            .pasted
        case .loading, .status:
            .processing
        }
    }

    private func present() {
        pauseTask?.cancel()
        isPaused = false
        engine.present(at: Date().timeIntervalSinceReferenceDate)
    }

    private func dismiss() {
        engine.dismiss(at: Date().timeIntervalSinceReferenceDate)
        // Stop redrawing once the orb has faded and the panel is hidden.
        pauseTask?.cancel()
        pauseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            isPaused = true
        }
    }

    private static func draw(_ frame: WaveEngine.Frame, in context: inout GraphicsContext, size: CGSize) {
        // Waves live in the inner rect; the margin is room for the blurred glow.
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: glowMargin.width, dy: glowMargin.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.blendMode = .plusLighter

        let width = rect.width * frame.spread
        if width > 1 {
            // Keep a faint moving line in silence; sqrt lifts typical speech levels.
            let amplitude = (rect.height / 2 - 3) * (0.06 + 0.94 * sqrt(frame.level)) * 1.6 * frame.spread
            // Additive strands overlap into white when flat, so dim them in silence.
            let brightness = (0.45 + 0.55 * min(1, frame.level * 2.5) + frame.flash) * frame.visibility
            let waveRect = CGRect(x: center.x - width / 2, y: rect.minY, width: width, height: rect.height)
            let start = CGPoint(x: waveRect.minX, y: 0)
            let end = CGPoint(x: waveRect.maxX, y: 0)

            let ribbons = strands.map { strand in
                let gradient = strand.isCyan ? cyanGradient : blueGradient
                return (
                    strand: strand,
                    shapes: shapes(for: strand, in: waveRect, amplitude: amplitude, frame: frame),
                    shading: GraphicsContext.Shading.linearGradient(gradient, startPoint: start, endPoint: end)
                )
            }

            // One blurred layer per halo: falls off smoothly with no visible edge.
            for (radius, lineWidth, strength) in [(10.0, 7.0, 0.55), (3.5, 3.0, 0.6)] {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: radius))
                    layer.blendMode = .plusLighter
                    for ribbon in ribbons {
                        layer.opacity = strength * ribbon.strand.gain * brightness
                        layer.stroke(ribbon.shapes.center, with: ribbon.shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    }
                }
            }

            for ribbon in ribbons {
                context.opacity = (0.45 + 0.5 * ribbon.strand.gain) * brightness
                context.fill(ribbon.shapes.ribbon, with: ribbon.shading)
            }

            if let scan = frame.scan {
                let scanCenter = CGPoint(x: center.x + scan * width * 0.32, y: center.y)
                let radius: CGFloat = 22
                context.opacity = frame.visibility * frame.spread
                context.fill(
                    Path(ellipseIn: CGRect(x: scanCenter.x - radius, y: scanCenter.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(scanGradient, center: scanCenter, startRadius: 0, endRadius: radius)
                )
            }
        }

        let orbOpacity = frame.visibility * pow(1 - frame.spread, 1.5)
        if orbOpacity > 0.01 {
            let radius = 16 * (0.4 + 0.6 * frame.visibility)
            context.opacity = orbOpacity
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(orbGradient, center: center, startRadius: 0, endRadius: radius)
            )
        }
    }

    /// The strand's centre line (for the halo) and a ribbon around it that is
    /// hairline at the ends and thickest in the middle.
    private static func shapes(
        for strand: Strand,
        in rect: CGRect,
        amplitude: CGFloat,
        frame: WaveEngine.Frame
    ) -> (center: Path, ribbon: Path) {
        let steps = max(2, Int(rect.width / 2))
        let limit = Double(rect.height / 2 - 3)
        let time = frame.clock
        let maxHalfWidth = (0.8 + 1.0 * frame.level) * strand.gain
        var points: [CGPoint] = []
        var halfWidths: [Double] = []
        points.reserveCapacity(steps + 1)
        halfWidths.reserveCapacity(steps + 1)

        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            // Bell curve: flat thin ends, full swing only in the middle.
            let envelope = exp(-pow((progress - 0.5) / 0.2, 2))
            // Slowly moving swell so humps rise and fall along the strand.
            let swell = 0.65 + 0.35 * sin(progress * .pi * 1.6 + time * strand.swellSpeed + strand.phase)
            let wave = sin(progress * .pi * 2 * strand.cycles + time * strand.speed + strand.phase)
            // Louder speech adds a faster ripple on top of the main wave.
            let ripple = frame.level * 0.3 * sin(progress * .pi * 2 * strand.cycles * 2.3 - time * strand.speed * 1.7)
            let raw = Double(amplitude) * strand.gain * envelope * swell * (wave + ripple)
            // Soft limit keeps loud peaks inside the frame without flat tops.
            let offset = limit * tanh(raw / limit)

            points.append(CGPoint(x: rect.minX + rect.width * progress, y: rect.midY + offset))
            halfWidths.append(0.3 + maxHalfWidth * envelope)
        }

        var center = Path()
        center.addLines(points)

        // Offset along the normal so steep slopes keep their thickness.
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        top.reserveCapacity(points.count)
        bottom.reserveCapacity(points.count)
        for index in points.indices {
            let previous = points[max(index - 1, 0)]
            let next = points[min(index + 1, points.count - 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let scale = halfWidths[index] / max(hypot(dx, dy), 0.001)
            let normal = CGPoint(x: -dy * scale, y: dx * scale)
            top.append(CGPoint(x: points[index].x + normal.x, y: points[index].y + normal.y))
            bottom.append(CGPoint(x: points[index].x - normal.x, y: points[index].y - normal.y))
        }

        var ribbon = Path()
        ribbon.addLines(top + bottom.reversed())
        ribbon.closeSubpath()

        return (center, ribbon)
    }

    private static func fadingGradient(_ color: Color) -> Gradient {
        Gradient(stops: [
            .init(color: color.opacity(0), location: 0),
            .init(color: color, location: 0.22),
            .init(color: color, location: 0.78),
            .init(color: color.opacity(0), location: 1),
        ])
    }
}

/// Per-frame state for WaveIndicatorView. Eases the chunky level updates,
/// keeps a wave clock that runs faster while speaking (so motion speeds up
/// without phase jumps), and drives the orb intro and collapse.
private final class WaveEngine {
    enum Mode {
        case listening
        case processing
        case pasted
    }

    struct Frame {
        var level: Double
        var clock: Double
        /// 0 is the collapsed orb, 1 is full-width waves.
        var spread: Double
        var visibility: Double
        var flash: Double
        /// Processing highlight position in -1...1.
        var scan: Double?
    }

    private var level = 0.0
    private var clock = 0.0
    private var spread = 0.0
    private var visibility = 0.0
    private var lastTime: TimeInterval?
    private var presentedAt: TimeInterval = 0
    private var dismissedAt: TimeInterval?
    private var pastedAt: TimeInterval?

    func present(at time: TimeInterval) {
        presentedAt = time
        dismissedAt = nil
        pastedAt = nil
        lastTime = nil
        level = 0
        spread = 0
        visibility = 0
    }

    func dismiss(at time: TimeInterval) {
        if dismissedAt == nil {
            dismissedAt = time
        }
    }

    func advance(mode: Mode, audioLevel: Double, at time: TimeInterval) -> Frame {
        let elapsed = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time

        let targetLevel: Double
        switch mode {
        case .listening:
            targetLevel = audioLevel
        case .processing:
            targetLevel = 0.1 + 0.05 * sin(time * 2.2)
        case .pasted:
            targetLevel = 0
            if pastedAt == nil {
                pastedAt = time
            }
        }
        level = Self.ease(level, toward: targetLevel, rate: targetLevel > level ? 35 : 10, elapsed: elapsed)
        clock += elapsed * (1 + 1.8 * level)

        // The orb pops in, then stretches into waves; dismissal reverses it.
        if let dismissedAt {
            spread = Self.ease(spread, toward: 0, rate: 12, elapsed: elapsed)
            let target = time - dismissedAt > 0.22 ? 0.0 : 1.0
            visibility = Self.ease(visibility, toward: target, rate: 16, elapsed: elapsed)
        } else {
            let target = time - presentedAt > 0.12 ? 1.0 : 0.0
            spread = Self.ease(spread, toward: target, rate: 10, elapsed: elapsed)
            visibility = Self.ease(visibility, toward: 1, rate: 22, elapsed: elapsed)
        }

        return Frame(
            level: level,
            clock: clock,
            spread: spread,
            visibility: visibility,
            flash: pastedAt.map { exp(-(time - $0) * 5) } ?? 0,
            scan: mode == .processing ? sin(time * 2.4) : nil
        )
    }

    private static func ease(_ value: Double, toward target: Double, rate: Double, elapsed: Double) -> Double {
        value + (target - value) * (1 - exp(-rate * elapsed))
    }
}

private struct TranscribingDotsView: View {
    private let dots = Array(0..<3)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 5) {
                ForEach(dots, id: \.self) { index in
                    Circle()
                        .frame(width: size(for: index, time: time), height: size(for: index, time: time))
                        .opacity(opacity(for: index, time: time))
                }
            }
            .frame(width: 30, height: 10)
        }
    }

    private func size(for index: Int, time: TimeInterval) -> CGFloat {
        3 + CGFloat(pulse(for: index, time: time)) * 2
    }

    private func opacity(for index: Int, time: TimeInterval) -> Double {
        0.35 + pulse(for: index, time: time) * 0.65
    }

    private func pulse(for index: Int, time: TimeInterval) -> Double {
        let phase = time * 5.2 - Double(index) * 0.58
        return (sin(phase) + 1) / 2
    }
}

private struct StatusTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .frame(height: 10)
    }
}

private struct LoadingStatusView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(time * 3.6) + 1) / 2

            StatusTextView(text: "Loading")
                .opacity(0.58 + pulse * 0.42)
                .scaleEffect(0.98 + pulse * 0.02)
        }
    }
}

private struct PastedStatusView: View {
    @State private var bounceID = false

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .symbolEffect(.bounce, options: .speed(1.8), value: bounceID)
            .frame(width: 30, height: 12)
            .onAppear {
                bounceID.toggle()
            }
    }
}

extension IndicatorStyle {
    /// FloatingIndicatorView's fixed frame for this style.
    var indicatorSize: CGSize {
        switch self {
        case .bars:
            CGSize(width: 72, height: 22)
        case .waves:
            // WaveIndicatorView: 240x80 waves plus the glow margin.
            CGSize(width: 280, height: 116)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        FloatingIndicatorView(model: FloatingIndicatorModel(content: .status(.recording), audioLevel: 0.8))
        FloatingIndicatorView(model: FloatingIndicatorModel(content: .status(.recording), audioLevel: 0.8, style: .waves))
        FloatingIndicatorView(model: FloatingIndicatorModel(content: .status(.transcribing)))
        FloatingIndicatorView(model: FloatingIndicatorModel(content: .loading))
        FloatingIndicatorView(model: FloatingIndicatorModel(content: .pasted))
    }
    .padding()
}

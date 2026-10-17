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
            WaveIndicatorView.size
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

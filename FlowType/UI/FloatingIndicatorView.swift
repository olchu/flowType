import Combine
import SwiftUI

@MainActor
final class FloatingIndicatorModel: ObservableObject {
    @Published var status: AppStatus = .ready
    @Published var isLoading = false
    @Published var audioLevel: Double = 0
    @Published var microphoneSensitivity: Double = 0.5
    @Published var presentationID = 0
    @Published var dismissalID = 0

    init(
        status: AppStatus = .ready,
        audioLevel: Double = 0,
        microphoneSensitivity: Double = 0.5
    ) {
        self.status = status
        self.audioLevel = audioLevel
        self.microphoneSensitivity = microphoneSensitivity
    }

    func update(
        status: AppStatus,
        audioLevel: Double,
        microphoneSensitivity: Double,
        startsNewPresentation: Bool
    ) {
        self.status = status
        isLoading = false
        self.audioLevel = audioLevel
        self.microphoneSensitivity = microphoneSensitivity

        if startsNewPresentation {
            presentationID += 1
        }
    }

    func updateLoading(startsNewPresentation: Bool) {
        status = .ready
        isLoading = true
        audioLevel = 0

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
        ZStack {
            Capsule()
                .fill(.black)
                .frame(width: isExpanded ? 72 : 8, height: isExpanded ? 20 : 8)

            content
                .foregroundStyle(.white)
                .opacity(showsContent ? 1 : 0)
        }
        .frame(width: 72, height: 22)
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
            if model.isLoading {
                LoadingStatusView()
            } else {
                switch model.status {
                case .recording:
                    RecordingBarsView(
                        audioLevel: model.audioLevel,
                        microphoneSensitivity: model.microphoneSensitivity
                    )
                case .transcribing:
                    TranscribingDotsView()
                case .ready:
                    EmptyView()
                case .error:
                    StatusTextView(text: "Error")
                }
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
    let microphoneSensitivity: Double

    private let bars = Array(0..<8)

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
        let threshold = 0.09 - min(max(microphoneSensitivity, 0), 1) * 0.08
        let gatedLevel = max(0, (audioLevel - threshold) / max(0.01, 1 - threshold))
        guard gatedLevel > 0 else { return 4 }

        let speeds: [Double] = [7.6, 4.9, 8.8, 5.7, 9.4, 6.5, 8.1, 5.2]
        let phases: [Double] = [0.1, 1.7, 3.4, 0.8, 2.6, 4.1, 1.2, 3.0]
        let beat = abs(sin(time * speeds[index] + phases[index]))
        let flicker = abs(sin(time * speeds[index] * 0.43 + phases[index] * 1.8))
        let level = min(1, (beat * 0.72 + flicker * 0.42) * (0.35 + gatedLevel * 1.15))
        return 3 + CGFloat(level) * 9
    }

    private func opacity(for index: Int, time: TimeInterval) -> Double {
        let threshold = 0.09 - min(max(microphoneSensitivity, 0), 1) * 0.08
        guard audioLevel > threshold else { return 0.38 }

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

            Text("Loading")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(height: 10)
                .opacity(0.58 + pulse * 0.42)
                .scaleEffect(0.98 + pulse * 0.02)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        FloatingIndicatorView(
            model: FloatingIndicatorModel(
                status: .recording,
                audioLevel: 0.8,
                microphoneSensitivity: 0.5
            )
        )
        FloatingIndicatorView(
            model: FloatingIndicatorModel(
                status: .transcribing,
                audioLevel: 0,
                microphoneSensitivity: 0.5
            )
        )
        FloatingIndicatorView(
            model: {
                let model = FloatingIndicatorModel()
                model.updateLoading(startsNewPresentation: true)
                return model
            }()
        )
    }
    .padding()
}

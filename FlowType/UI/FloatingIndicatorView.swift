import SwiftUI

struct FloatingIndicatorView: View {
    let status: AppStatus

    var body: some View {
        HStack(spacing: 12) {
            switch status {
            case .recording:
                RecordingBarsView()
            case .transcribing:
                TranscribingLettersView()
            case .ready:
                EmptyView()
            case .error:
                StatusTextView(text: "Error")
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 54, minHeight: 20)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.92), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 8)
    }
}

private struct RecordingBarsView: View {
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
            .frame(width: 30, height: 16)
        }
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        let speeds: [Double] = [7.6, 4.9, 8.8, 5.7, 9.4, 6.5, 8.1, 5.2]
        let phases: [Double] = [0.1, 1.7, 3.4, 0.8, 2.6, 4.1, 1.2, 3.0]
        let beat = abs(sin(time * speeds[index] + phases[index]))
        let flicker = abs(sin(time * speeds[index] * 0.43 + phases[index] * 1.8))
        let level = min(1, beat * 0.72 + flicker * 0.42)
        return 4 + CGFloat(level) * 12
    }

    private func opacity(for index: Int, time: TimeInterval) -> Double {
        let phase = time * (6.0 + Double(index).truncatingRemainder(dividingBy: 3)) + Double(index)
        let normalized = abs(sin(phase))
        return 0.5 + normalized * 0.5
    }
}

private struct TranscribingLettersView: View {
    private let letters = Array("TRANSCRIPT")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 1) {
                ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .opacity(opacity(for: index, time: time))
                        .offset(y: offset(for: index, time: time))
                }
            }
            .frame(width: 64, height: 12)
        }
    }

    private func opacity(for index: Int, time: TimeInterval) -> Double {
        let phase = time * 3.2 - Double(index) * 0.24
        let normalized = (sin(phase) + 1) / 2
        return 0.22 + normalized * 0.78
    }

    private func offset(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = time * 3.2 - Double(index) * 0.24
        return CGFloat((1 - (sin(phase) + 1) / 2) * 3)
    }
}

private struct StatusTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .frame(height: 12)
    }
}

#Preview {
    VStack(spacing: 20) {
        FloatingIndicatorView(status: .recording)
        FloatingIndicatorView(status: .transcribing)
    }
    .padding()
}

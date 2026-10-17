import SwiftUI

/// Rounded, tinted symbol in the style of System Settings.
struct SettingsIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.gradient)
            )
            .accessibilityHidden(true)
    }
}

/// Small capsule with a coloured dot, for states such as "Granted" or "Downloaded".
struct StatusBadge: View {
    enum Tone {
        case positive
        case warning
        case negative
        case neutral
        case accent

        var color: Color {
            switch self {
            case .positive:
                .green
            case .warning:
                .orange
            case .negative:
                .red
            case .neutral:
                .secondary
            case .accent:
                .accentColor
            }
        }
    }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)

            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.color.opacity(0.12), in: .capsule)
    }
}

/// A keyboard key, used to show the dictation hotkey.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.separator)
            )
    }
}

/// Slider with speaker icons and a percentage, shared by the sensitivity and
/// volume settings.
struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    var onEditingEnded: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)

                Spacer()

                Text("\(Int((value * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $value, in: 0...1) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            } onEditingChanged: { isEditing in
                if !isEditing {
                    onEditingEnded?()
                }
            }
            .labelsHidden()
        }
    }
}

extension ModelStorageState {
    var color: Color {
        switch self {
        case .downloaded:
            .green
        case .notDownloaded:
            .secondary
        case .downloading, .deleting:
            .orange
        case .error:
            .red
        }
    }

    var canDownload: Bool {
        switch self {
        case .notDownloaded, .error:
            true
        case .downloaded, .downloading, .deleting:
            false
        }
    }
}

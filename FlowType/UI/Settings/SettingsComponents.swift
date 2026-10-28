import SwiftUI

/// A monochrome symbol on a soft tile, beside a row's title.
struct SettingsIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14.5, weight: .medium))
            .frame(width: 30, height: 30)
            .background(SettingsStyle.fill, in: .rect(cornerRadius: 8.5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Small capsule with a coloured dot, for states such as "Granted" or "Downloaded".
struct StatusBadge: View {
    enum Tone {
        case positive
        case warning
        case negative

        var color: Color {
            switch self {
            case .positive:
                .green
            case .warning:
                .orange
            case .negative:
                .red
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
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)

            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(SettingsStyle.fill, in: .capsule)
    }
}

/// A keyboard key, used to show the dictation hotkey.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(SettingsStyle.fill, in: .rect(cornerRadius: 8, style: .continuous))
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

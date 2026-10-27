import AppKit
import SwiftUI

struct IndicatorSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    /// The Wave Tuner is a design tool, hidden until Option is pressed three
    /// times in a row in this pane; it then stays until the pane is left.
    @State private var showsTuner = false
    @State private var optionKeyMonitor: Any?
    @State private var optionPresses: [Date] = []

    var body: some View {
        Form {
            Section {
                IndicatorPreview(appearance: appState.settings.indicatorAppearance)
            }

            Section("Appearance") {
                Picker("Animation", selection: $appState.settings.indicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                if appState.settings.indicatorStyle.usesAuroraPalette {
                    LabeledContent("Palette") {
                        HStack(spacing: 4) {
                            ForEach(AuroraPalette.allCases) { palette in
                                auroraPaletteSwatch(palette)
                            }
                        }
                    }
                }

                if appState.settings.indicatorStyle.usesWaveColor {
                    LabeledContent("Color") {
                        HStack(spacing: 4) {
                            ForEach(WaveColor.allCases) { color in
                                waveColorSwatch(color)
                            }
                        }
                    }

                    // The tuner only edits the waves.
                    if showsTuner && appState.settings.indicatorStyle == .waves {
                        LabeledContent("Glow and layers") {
                            Button("Fine-tune…") {
                                openWindow(id: "wave-tuner")
                                NSApplication.shared.activate(ignoringOtherApps: true)
                            }
                        }
                    }
                }
            }

            Section {
                PercentSlider(
                    title: "Sensitivity",
                    value: $appState.settings.microphoneSensitivity
                )
            } header: {
                Text("Microphone")
            } footer: {
                Text("Lower values ignore more background noise. Higher values make the indicator react to quieter speech.")
            }
        }
        .onAppear {
            optionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                // Count presses only, not releases.
                if event.modifierFlags.contains(.option) {
                    registerOptionPress()
                }
                return event
            }
        }
        .onDisappear {
            if let optionKeyMonitor {
                NSEvent.removeMonitor(optionKeyMonitor)
            }
            optionKeyMonitor = nil
            optionPresses = []
            showsTuner = false
        }
    }

    private func registerOptionPress() {
        let now = Date.now
        optionPresses = optionPresses.filter { now.timeIntervalSince($0) < 1 } + [now]
        if optionPresses.count >= 3 {
            showsTuner = true
            optionPresses = []
        }
    }

    private func waveColorSwatch(_ color: WaveColor) -> some View {
        let palette = color.palette
        return swatch(
            colors: [Color(cgColor: palette.primary), Color(cgColor: palette.secondary)],
            name: color.rawValue,
            isSelected: appState.settings.waveColor == color
        ) {
            appState.settings.waveColor = color
        }
    }

    private func auroraPaletteSwatch(_ palette: AuroraPalette) -> some View {
        swatch(
            colors: palette.swatchColors,
            name: palette.rawValue,
            isSelected: appState.settings.auroraPalette == palette
        ) {
            appState.settings.auroraPalette = palette
        }
    }

    private func swatch(
        colors: [Color], name: String, isSelected: Bool, select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay {
                    Circle()
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The real floating indicator on a desktop-like backdrop, fed with a
/// speech-like level so the selected style and colour can be seen moving.
private struct IndicatorPreview: View {
    let appearance: IndicatorAppearance

    @StateObject private var model = FloatingIndicatorModel(content: .status(.recording), audioLevel: 0.4)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.16, blue: 0.3),
                            Color(red: 0.24, green: 0.2, blue: 0.42),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            FloatingIndicatorView(model: model)
                .scaleEffect(appearance.style == .bars ? 2 : 1)

            Text("Preview")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the \(appearance.style.rawValue) indicator")
        .onAppear {
            show(startsNewPresentation: true)
        }
        .onChange(of: appearance) { old, new in
            // A new style plays its intro; a new colour just recolours it.
            show(startsNewPresentation: new.style != old.style)
        }
        .task {
            // Rising and falling level, like a few spoken words.
            let start = Date.now
            while !Task.isCancelled {
                let time = Date.now.timeIntervalSince(start)
                let words = abs(sin(time * 2.3)) * (0.55 + 0.45 * sin(time * 0.7))
                model.audioLevel = max(0, 0.15 + 0.55 * words)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func show(startsNewPresentation: Bool) {
        model.show(.status(.recording), appearance: appearance, startsNewPresentation: startsNewPresentation)
    }
}

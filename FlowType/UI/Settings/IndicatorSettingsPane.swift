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
        SettingsPage(.indicator) {
            IndicatorPreview(appearance: appState.settings.indicatorAppearance)

            SettingsSection("Appearance") {
                SettingsSegmentedPicker(
                    label: "Animation",
                    selection: $appState.settings.indicatorStyle,
                    options: IndicatorStyle.allCases,
                    title: \.rawValue
                )

                if appState.settings.indicatorStyle.usesAuroraPalette {
                    SettingsRow("Palette") {
                        HStack(spacing: 4) {
                            ForEach(AuroraPalette.allCases) { palette in
                                auroraPaletteSwatch(palette)
                            }
                        }
                    }
                }

                if appState.settings.indicatorStyle.usesWaveColor {
                    SettingsRow("Color") {
                        HStack(spacing: 4) {
                            ForEach(WaveColor.allCases) { color in
                                waveColorSwatch(color)
                            }
                        }
                    }

                    // The tuner only edits the waves.
                    if showsTuner && appState.settings.indicatorStyle == .waves {
                        SettingsRow("Glow and layers") {
                            Button("Fine-tune…") {
                                openWindow(id: "wave-tuner")
                                NSApplication.shared.activate(ignoringOtherApps: true)
                            }
                        }
                    }
                }
            }

            SettingsSection(
                "Position",
                footer: "Choose, then drag the indicator anywhere on any screen. It appears there every time; if that screen is gone, it goes back above the Dock."
            ) {
                SettingsRow(
                    "Position",
                    subtitle: appState.isPositioningIndicator
                        ? "Drag the indicator, then click Done."
                        : (appState.settings.indicatorPosition == nil ? "Above the Dock" : "Where you placed it")
                ) {
                    HStack(spacing: 8) {
                        if appState.isPositioningIndicator {
                            Button("Cancel") {
                                appState.finishIndicatorPositioning(keeps: false)
                            }

                            Button("Done") {
                                appState.finishIndicatorPositioning(keeps: true)
                            }
                            .buttonStyle(.settingsProminent)
                        } else {
                            if appState.settings.indicatorPosition != nil {
                                Button("Reset") {
                                    appState.settings.indicatorPosition = nil
                                }
                            }

                            Button("Choose…") {
                                appState.beginIndicatorPositioning()
                            }
                        }
                    }
                }
            }

            SettingsSection("Microphone", footer: "Lower values ignore more background noise. Higher values make the indicator react to quieter speech.") {
                PercentSlider(
                    title: "Sensitivity",
                    value: $appState.settings.microphoneSensitivity
                )
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
            // Leaving the pane keeps where the indicator was dragged.
            appState.finishIndicatorPositioning(keeps: true)
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
                        .strokeBorder(isSelected ? SettingsStyle.ink : .clear, lineWidth: 2)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SettingsStyle.preview)

            FloatingIndicatorView(model: model)
                .scaleEffect(appearance.style == .bars ? 2 : 1)

            Text("Preview")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
        }
        .frame(height: 170)
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
            await DemoVoice.drive(model)
        }
    }

    private func show(startsNewPresentation: Bool) {
        model.show(.status(.recording), appearance: appearance, startsNewPresentation: startsNewPresentation)
    }
}

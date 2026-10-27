import AppKit
import SwiftUI

/// Live editor for every layer of the waves indicator. Changes apply to the
/// real indicator too, so they can be checked with Fn over any app.
struct WaveTunerView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = WaveAppearanceStore.shared
    @StateObject private var model = FloatingIndicatorModel(
        content: .status(.recording),
        audioLevel: 0.6,
        style: .waves
    )

    @State private var animatesVoice = true
    @State private var level = 0.6
    @State private var isProcessing = false
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 0) {
            previews
                .frame(width: 340)
                .padding(16)

            Divider()

            controls
                .frame(minWidth: 420)
        }
        .frame(minWidth: 800, minHeight: 680)
        .onAppear {
            show(startsNewPresentation: true)
        }
        .onChange(of: appState.settings.waveColor) {
            show(startsNewPresentation: false)
        }
        .onChange(of: isProcessing) {
            show(startsNewPresentation: false)
        }
        .onChange(of: level) {
            if !animatesVoice {
                model.audioLevel = level
            }
        }
        .task(id: animatesVoice) {
            guard animatesVoice else {
                model.audioLevel = level
                return
            }
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

    private var previews: some View {
        VStack(spacing: 12) {
            previewTile("White", background: .white, labelColor: .black)
            previewTile("Light gray", background: Color(white: 0.9), labelColor: .black)
            previewTile("Dark", background: Color(white: 0.12), labelColor: .white)
        }
    }

    private func previewTile(_ title: String, background: Color, labelColor: Color) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator)
                )

            WaveIndicatorView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(labelColor.opacity(0.5))
                .padding(8)
        }
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        Form {
            Section("Preview") {
                Toggle("Animate voice", isOn: $animatesVoice)

                valueSlider("Voice level", value: $level, in: 0...1)
                    .disabled(animatesVoice)

                Picker("State", selection: $isProcessing) {
                    Text("Listening").tag(false)
                    Text("Processing").tag(true)
                }
                .pickerStyle(.segmented)

                Picker("Color", selection: $appState.settings.waveColor) {
                    ForEach(WaveColor.allCases) { color in
                        Text(color.rawValue).tag(color)
                    }
                }

                Button("Replay Intro") {
                    show(startsNewPresentation: true)
                }
            }

            Section {
                Toggle("Show halo", isOn: $store.appearance.showsHalo)
                Group {
                    valueSlider("Opacity", value: $store.appearance.haloOpacity, in: 0...1)
                    valueSlider("Blur radius", value: $store.appearance.haloRadius, in: 0...30)
                    valueSlider("Spread", value: $store.appearance.haloSpread, in: 0...15)
                    valueSlider("Whiteness", value: $store.appearance.haloWhiteness, in: 0...1)
                }
                .disabled(!store.appearance.showsHalo)
            } header: {
                Text("Halo")
            } footer: {
                Text("Wide soft glow around each strand. Overlapping halos build up in the middle of the bundle.")
            }

            Section {
                Toggle("Show glow", isOn: $store.appearance.showsGlow)
                Group {
                    valueSlider("Opacity", value: $store.appearance.glowOpacity, in: 0...1)
                    valueSlider("Blur radius", value: $store.appearance.glowRadius, in: 0...12)
                    valueSlider("Whiteness", value: $store.appearance.glowWhiteness, in: 0...1)
                }
                .disabled(!store.appearance.showsGlow)
            } header: {
                Text("Glow")
            } footer: {
                Text("Tight glow hugging each strand.")
            }

            Section("Lines") {
                Toggle("Show lines", isOn: $store.appearance.showsLines)
                Group {
                    valueSlider("Opacity", value: $store.appearance.lineOpacity, in: 0...1)
                    valueSlider("Width", value: $store.appearance.lineWidth, in: 0.3...3)
                    valueSlider("Whiteness", value: $store.appearance.lineWhiteness, in: 0...1)
                }
                .disabled(!store.appearance.showsLines)
            }

            Section {
                Toggle("Additive blending", isOn: $store.appearance.usesAdditiveBlending)
                Toggle("Show orb", isOn: $store.appearance.showsOrb)
            } header: {
                Text("Compositing")
            } footer: {
                Text("Additive blending makes crossings brighter. Off uses normal blending.")
            }

            Section {
                HStack {
                    Button("Reset to Defaults") {
                        store.appearance = WaveAppearance()
                    }

                    Spacer()

                    Button(didCopy ? "Copied" : "Copy Values") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.appearance.summary, forType: .string)
                        didCopy = true
                    }
                }
            } footer: {
                Text("Changes are saved and used by the real indicator. Hold Fn over any window to check them.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.appearance) {
            didCopy = false
        }
    }

    private func valueSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .frame(width: 180)

                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func show(startsNewPresentation: Bool) {
        model.show(
            .status(isProcessing ? .transcribing : .recording),
            appearance: IndicatorAppearance(style: .waves, waveColor: appState.settings.waveColor),
            startsNewPresentation: startsNewPresentation
        )
    }
}

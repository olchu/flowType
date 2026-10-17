import SwiftUI

struct SoundsSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appState.settings.playsSounds) {
                    Text("Play feedback sounds")
                    Text("Short cues confirm each step, so you don't need to watch the screen.")
                }
            }

            Section {
                PercentSlider(title: "Volume", value: $appState.settings.soundVolume) {
                    appState.previewFeedbackSound()
                }
            }
            .disabled(!appState.settings.playsSounds)

            Section {
                ForEach(FeedbackSound.allCases, id: \.self) { sound in
                    HStack {
                        Text(sound.title)

                        Spacer()

                        Button {
                            appState.previewFeedbackSound(sound)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Play \(sound.title)")
                    }
                }
            } header: {
                Text("Cues")
            } footer: {
                Text("When sounds are off, the waves react to your voice right away instead of waiting for the start cue to end.")
            }
            .disabled(!appState.settings.playsSounds)
        }
    }
}

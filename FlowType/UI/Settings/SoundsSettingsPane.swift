import SwiftUI

struct SoundsSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPage(.sounds) {
            SettingsSection("Feedback") {
                SettingsToggle(
                    "Play feedback sounds",
                    subtitle: "Short cues confirm each step, so you don't need to watch the screen.",
                    isOn: $appState.settings.playsSounds
                )

                PercentSlider(title: "Volume", value: $appState.settings.soundVolume) {
                    appState.previewFeedbackSound()
                }
                .disabled(!appState.settings.playsSounds)
            }

            SettingsSection("Cues", footer: "When sounds are off, the waves react to your voice right away instead of waiting for the start cue to end.") {
                ForEach(FeedbackSound.allCases, id: \.self) { sound in
                    SettingsRow(sound.title) {
                        Button {
                            appState.previewFeedbackSound(sound)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Play \(sound.title)")
                    }
                }
            }
            .disabled(!appState.settings.playsSounds)
        }
    }
}

import SwiftUI

struct TextRulesSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    /// The filler list as typed. Kept apart from the settings so a comma just
    /// typed isn't tidied away under the cursor.
    @State private var fillerWordsDraft = ""

    var body: some View {
        SettingsPage(.textRules) {
            SettingsSection("Filler words", footer: "Separate words with commas. A word goes only where it stands apart, at the start of a phrase or between commas, so \u{201C}что-то типа этого\u{201D} stays. Sounds like \u{201C}э\u{201D}, \u{201C}ммм\u{201D}, \u{201C}uh\u{201D} and \u{201C}um\u{201D} always go.") {
                SettingsToggle(
                    "Remove filler words",
                    subtitle: "\u{201C}Ну, короче, давай\u{201D} becomes \u{201C}Давай\u{201D}, \u{201C}So, like, what now?\u{201D} becomes \u{201C}So, what now?\u{201D}",
                    isOn: $appState.settings.removesFillerWords
                )

                if appState.settings.removesFillerWords {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("Words", text: $fillerWordsDraft, prompt: Text("ну, типа, как бы"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .labelsHidden()

                        Button("Reset to Defaults") {
                            fillerWordsDraft = FillerWords.defaults.joined(separator: ", ")
                        }
                        .disabled(appState.settings.fillerWords == FillerWords.defaults)
                    }
                }
            }

            SettingsSection("Numbers", footer: "Russian and English: numbers in any case, ordinals, percentages, money, times, dates and years (\u{201C}25 октября\u{201D}, \u{201C}в 2026 году\u{201D}, \u{201C}October 5\u{201D}, \u{201C}nineteen ninety\u{201D} \u{2192} 1990). Percentages, money, times and dates always use digits.") {
                SettingsToggle(
                    "Write numbers as digits",
                    subtitle: "\u{201C}Двадцать пять процентов\u{201D} becomes \u{201C}25%\u{201D}, \u{201C}at nine thirty\u{201D} becomes \u{201C}at 9:30\u{201D}.",
                    isOn: $appState.settings.writesNumbersAsDigits
                )

                if appState.settings.writesNumbersAsDigits {
                    SettingsToggle(
                        "Keep numbers under ten as words",
                        subtitle: "\u{201C}У меня два кота\u{201D} and \u{201C}two cats\u{201D} stay as they are, as in edited text.",
                        isOn: $appState.settings.keepsSmallNumbersAsWords
                    )
                }
            }
        }
        .onAppear {
            fillerWordsDraft = appState.settings.fillerWords.joined(separator: ", ")
        }
        .onChange(of: fillerWordsDraft) {
            let words = fillerWordsDraft
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // A comma or a space just typed doesn't change the list.
            if words != appState.settings.fillerWords {
                appState.settings.fillerWords = words
            }
        }
    }
}

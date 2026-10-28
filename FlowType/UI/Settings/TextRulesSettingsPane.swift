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

            SettingsSection("Punctuation", footer: "Say \u{201C}точка\u{201D}, \u{201C}запятая\u{201D}, \u{201C}точка с запятой\u{201D}, \u{201C}двоеточие\u{201D}, \u{201C}многоточие\u{201D}, \u{201C}тире\u{201D}, \u{201C}вопросительный знак\u{201D} or \u{201C}знак вопроса\u{201D}, \u{201C}восклицательный знак\u{201D}, \u{201C}открыть кавычки\u{201D}, \u{201C}закрыть кавычки\u{201D}, \u{201C}открыть скобку\u{201D}, \u{201C}закрыть скобку\u{201D}, \u{201C}новая строка\u{201D}, \u{201C}новый абзац\u{201D}, or \u{201C}period\u{201D}, \u{201C}comma\u{201D}, \u{201C}semicolon\u{201D}, \u{201C}colon\u{201D}, \u{201C}ellipsis\u{201D}, \u{201C}dash\u{201D}, \u{201C}question mark\u{201D}, \u{201C}exclamation mark\u{201D}, \u{201C}open quote\u{201D}, \u{201C}close quote\u{201D}, \u{201C}open bracket\u{201D}, \u{201C}close bracket\u{201D}, \u{201C}new line\u{201D}, \u{201C}new paragraph\u{201D}. Commands that are also everyday words, like \u{201C}точка\u{201D} or \u{201C}новая строка\u{201D}, work only before a short pause, so \u{201C}точка зрения\u{201D} stays.") {
                SettingsToggle(
                    "Write spoken punctuation",
                    subtitle: "\u{201C}Привет, запятая, как дела, вопросительный знак\u{201D} becomes \u{201C}Привет, как дела?\u{201D}",
                    isOn: $appState.settings.writesSpokenPunctuation
                )
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

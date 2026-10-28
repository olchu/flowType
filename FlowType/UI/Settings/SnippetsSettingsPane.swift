import SwiftUI

struct SnippetsSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPage(.snippets) {
            ForEach($appState.snippets) { $snippet in
                SettingsSection(snippet.triggers.first ?? "New snippet") {
                    SettingsRow("Say") {
                        TextField("Phrases", text: $snippet.phrases, prompt: Text("моя почта, мой имейл"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(maxWidth: 320)
                    }

                    SettingsRow("To write") {
                        TextField("Text", text: $snippet.text, prompt: Text("name@example.com"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .lineLimit(1...6)
                            .frame(maxWidth: 320)
                    }

                    SettingsToggle(
                        "Also inside a phrase",
                        subtitle: "\u{201C}Напиши на моя почта\u{201D} works too, not only a dictation of just the phrase.",
                        isOn: $snippet.worksInsidePhrase
                    )

                    SettingsRow("Remove snippet") {
                        Button("Remove", role: .destructive) {
                            appState.snippets.removeAll { $0.id == snippet.id }
                        }
                    }
                }
            }

            SettingsSection(
                appState.snippets.isEmpty ? "Your snippets" : "More",
                footer: "Say a phrase on its own, and its text is pasted exactly as written. Separate phrases that mean the same with commas. Snippets are kept in the Keychain."
            ) {
                SettingsRow("Add a snippet", subtitle: "Your email, phone number, address or a signature.") {
                    Button("Add Snippet") {
                        appState.snippets.append(Snippet())
                    }
                    .buttonStyle(.settingsProminent)
                }
            }
        }
    }
}

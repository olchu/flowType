import SwiftUI

/// The recent dictations; a click pastes one into the app in front.
struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var history: DictationHistory
    @State private var query = ""
    @State private var isConfirmingClear = false

    var body: some View {
        let entries = matchingEntries
        List(entries) { entry in
            HistoryRow(entry: entry)
                .contentShape(.rect)
                .onTapGesture {
                    appState.pasteFromHistory(entry)
                }
                .help("Click to paste into the app in front")
                .contextMenu {
                    Button("Paste") {
                        appState.pasteFromHistory(entry)
                    }
                    Button("Copy") {
                        appState.copy(entry.text)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        history.remove(entry)
                    }
                }
        }
        .overlay {
            if entries.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if appState.settings.keepsHistory {
                    ContentUnavailableView("No Dictations Yet", systemImage: "clock", description: Text("Your dictations from the past week appear here."))
                } else {
                    ContentUnavailableView("History Is Off", systemImage: "clock", description: Text("Turn on Keep history in Settings → General to save your dictations."))
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Button("Clear History", systemImage: "trash") {
                    isConfirmingClear = true
                }
                .disabled(history.entries.isEmpty)
            }
        }
        .clearHistoryConfirmation(isPresented: $isConfirmingClear, history: history)
        .frame(minWidth: 460, minHeight: 360)
    }

    private var matchingEntries: [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.localizedStandardContains(query) }
    }
}

extension View {
    /// Asks before clearing the history.
    func clearHistoryConfirmation(isPresented: Binding<Bool>, history: DictationHistory) -> some View {
        confirmationDialog("Clear the history?", isPresented: isPresented) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
        } message: {
            Text("Every saved dictation is deleted from this Mac.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(entry.date, format: .relative(presentation: .named))
                if let appName = entry.appName {
                    Text("·")
                    Text(appName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

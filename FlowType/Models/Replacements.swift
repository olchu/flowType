import Foundation

/// A dictionary entry: a phrase as it is heard, and how to write it.
nonisolated struct WordReplacement: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var heard = ""
    var written = ""
}

/// Text that a short spoken phrase stands for: "моя почта" → the address.
/// Kept in the Keychain, as it holds addresses and phone numbers.
nonisolated struct Snippet: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// The phrases that say it, as typed: "моя почта, мой имейл". Kept as
    /// typed so a comma just typed isn't tidied away under the cursor.
    var phrases = ""
    var text = ""
    /// Also when said inside a phrase ("напиши на моя почта"), not only as
    /// a dictation of its own.
    var worksInsidePhrase = false

    var triggers: [String] {
        phrases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

import Combine
import CryptoKit
import Foundation

nonisolated struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    let text: String
    /// The app the dictation went into.
    let appName: String?
}

/// The recent dictations, up to 100 from the past week, kept on disk sealed
/// with a key that lives in the Keychain, so the file alone reads as noise.
final class DictationHistory: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private static let limit = 100
    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let keyAccount = "history-key"

    private let fileURL: URL
    /// Read from the Keychain once, not on every dictation.
    private var key: SymmetricKey?

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "FlowType")
        fileURL = directory.appending(path: "History.sealed")
        entries = load()
        let count = entries.count
        prune()
        // So the file doesn't keep what has aged out either.
        if entries.count != count {
            save()
        }
    }

    func add(_ text: String, appName: String?) {
        entries.insert(HistoryEntry(text: text, appName: appName), at: 0)
        prune()
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func prune() {
        let oldest = Date.now.addingTimeInterval(-Self.maximumAge)
        entries = Array(entries.prefix { $0.date >= oldest }.prefix(Self.limit))
    }

    private func load() -> [HistoryEntry] {
        guard let sealed = try? Data(contentsOf: fileURL),
              let key = key(createsIfMissing: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key)
        else {
            return []
        }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let key = key(createsIfMissing: true),
              let data = try? JSONEncoder().encode(entries),
              let sealed = try? AES.GCM.seal(data, using: key).combined
        else {
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: fileURL, options: .atomic)
    }

    private func key(createsIfMissing: Bool) -> SymmetricKey? {
        if let key {
            return key
        }
        if let data = Keychain.data(for: Self.keyAccount) {
            key = SymmetricKey(data: data)
        } else if createsIfMissing {
            let newKey = SymmetricKey(size: .bits256)
            guard Keychain.set(newKey.withUnsafeBytes { Data($0) }, for: Self.keyAccount) else { return nil }
            key = newKey
        }
        return key
    }
}

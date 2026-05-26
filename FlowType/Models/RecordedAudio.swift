import Foundation

struct RecordedAudio {
    let samples: [Float]
    let sampleRate: Double
    let temporaryFileURL: URL?

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / sampleRate
    }

    var isEmpty: Bool {
        samples.isEmpty
    }

    func removeTemporaryFile() {
        guard let temporaryFileURL else { return }
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }
}

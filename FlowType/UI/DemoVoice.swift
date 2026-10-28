import Foundation

/// A made-up voice for showing the indicator without speaking: a level that
/// rises and falls like a few spoken words, and a spectrum that shifts like
/// vowels and consonants, strongest in the low middle.
enum DemoVoice {
    static func sample(at time: TimeInterval) -> (level: Double, bands: SpectrumBands) {
        let words = abs(sin(time * 2.3)) * (0.55 + 0.45 * sin(time * 0.7))
        var bands = SpectrumBands()
        for band in 0..<SpectrumAnalyzer.bandCount {
            let shape = 0.35 + 0.65 * abs(sin(time * (1.1 + 0.29 * Double(band)) + Double(band) * 1.7))
            let voice = exp(-pow((Double(band) - 2.5) / 3.5, 2))
            bands[band] = Float(shape * voice)
        }
        return (max(0, 0.15 + 0.55 * words), bands)
    }

    /// Speaks into `model` until the task is cancelled.
    @MainActor
    static func drive(_ model: FloatingIndicatorModel) async {
        let start = Date.now
        while !Task.isCancelled {
            let sample = sample(at: Date.now.timeIntervalSince(start))
            model.audioLevel = sample.level
            model.audioBands = sample.bands
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

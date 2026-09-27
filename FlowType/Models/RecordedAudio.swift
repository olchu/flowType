import Foundation

nonisolated struct RecordedAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / sampleRate
    }

    var isEmpty: Bool {
        samples.isEmpty
    }

    var containsLikelySpeech: Bool {
        guard duration >= 0.35, !samples.isEmpty else { return false }

        let rms = rootMeanSquareLevel
        let activeRatio = activeSampleRatio(above: 0.025)
        return rms >= 0.012 && activeRatio >= 0.005
    }

    func suffix(seconds: TimeInterval) -> RecordedAudio {
        guard seconds > 0, sampleRate > 0, !samples.isEmpty else {
            return self
        }

        let sampleCount = min(samples.count, Int((seconds * sampleRate).rounded()))
        return RecordedAudio(
            samples: Array(samples.suffix(sampleCount)),
            sampleRate: sampleRate
        )
    }

    func suffix(from seconds: TimeInterval) -> RecordedAudio {
        guard seconds > 0, sampleRate > 0 else {
            return self
        }

        let startIndex = min(samples.count, Int((seconds * sampleRate).rounded()))
        return RecordedAudio(
            samples: Array(samples[startIndex...]),
            sampleRate: sampleRate
        )
    }

    func prefix(seconds: TimeInterval) -> RecordedAudio {
        guard seconds > 0, sampleRate > 0 else {
            return RecordedAudio(samples: [], sampleRate: sampleRate)
        }

        let sampleCount = min(samples.count, Int((seconds * sampleRate).rounded()))
        return RecordedAudio(
            samples: Array(samples.prefix(sampleCount)),
            sampleRate: sampleRate
        )
    }

    /// Frame-level RMS energies, used for a lightweight voice activity check.
    func frameLevels(frameSeconds: TimeInterval = 0.03) -> [Float] {
        let frameLength = max(1, Int(frameSeconds * sampleRate))
        guard samples.count >= frameLength else { return [] }

        return stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { start in
            var sumSquares: Float = 0
            for index in start..<(start + frameLength) {
                sumSquares += samples[index] * samples[index]
            }
            return sqrt(sumSquares / Float(frameLength))
        }
    }

    /// Background level of the recording: the energy of its quietest frames.
    var noiseFloor: Float {
        let levels = frameLevels().sorted()
        guard !levels.isEmpty else { return 0 }
        return levels[levels.count / 10]
    }

    /// Returns the end time of the last speech-like frame, or `nil` when the
    /// audio holds less than `minimumSpeech` of energy above the noise floor.
    /// Whisper tends to invent text ("Продолжение следует...") for silence, so
    /// silent tails must never reach the decoder.
    func lastSpeechEnd(noiseFloor: Float, minimumSpeech: TimeInterval = 0.15) -> TimeInterval? {
        let frameSeconds = 0.03
        let levels = frameLevels(frameSeconds: frameSeconds)
        let threshold = max(0.006, noiseFloor * 3)
        let speechFrames = levels.indices.filter { levels[$0] >= threshold }

        guard let lastFrame = speechFrames.last,
              Double(speechFrames.count) * frameSeconds >= minimumSpeech else {
            return nil
        }

        return Double(lastFrame + 1) * frameSeconds
    }

    func samples(resampledTo targetSampleRate: Double) -> [Float] {
        guard sampleRate > 0, targetSampleRate > 0, !samples.isEmpty else {
            return samples
        }

        guard abs(sampleRate - targetSampleRate) > 0.5 else {
            return samples
        }

        guard samples.count > 1 else {
            return samples
        }

        let targetCount = max(1, Int((Double(samples.count) * targetSampleRate / sampleRate).rounded()))
        let sourceStep = sampleRate / targetSampleRate

        return (0..<targetCount).map { index in
            let sourcePosition = Double(index) * sourceStep
            let lowerIndex = min(Int(sourcePosition), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))

            return samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
    }

    private var rootMeanSquareLevel: Double {
        guard !samples.isEmpty else { return 0 }

        let sumSquares = samples.reduce(0) { partialResult, sample in
            partialResult + Double(sample * sample)
        }
        return sqrt(sumSquares / Double(samples.count))
    }

    private func activeSampleRatio(above threshold: Float) -> Double {
        guard !samples.isEmpty else { return 0 }

        let activeSampleCount = samples.reduce(0) { partialResult, sample in
            partialResult + (abs(sample) >= threshold ? 1 : 0)
        }
        return Double(activeSampleCount) / Double(samples.count)
    }
}

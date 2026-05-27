import Foundation

struct RecordedAudio {
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

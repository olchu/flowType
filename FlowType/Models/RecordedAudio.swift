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
}

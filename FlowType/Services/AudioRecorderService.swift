import AVFoundation
import Foundation

@MainActor
final class AudioRecorderService {
    enum AudioRecorderError: LocalizedError {
        case noInputDevice
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "No microphone input device is available."
            case .alreadyRecording:
                "Recording is already in progress."
            }
        }
    }

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var isRecording = false
    var onLevelChanged: ((Double) -> Void)?

    func startRecording() throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        samples.removeAll(keepingCapacity: true)
        sampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            var monoSamples: [Float] = []
            monoSamples.reserveCapacity(frameCount)
            var sumSquares: Float = 0

            for frame in 0..<frameCount {
                var sample: Float = 0

                for channel in 0..<channelCount {
                    sample += channelData[channel][frame]
                }

                let monoSample = sample / Float(channelCount)
                monoSamples.append(monoSample)
                sumSquares += monoSample * monoSample
            }

            let level = Self.level(sumSquares: sumSquares, frameCount: frameCount)

            Task { @MainActor in
                self?.appendSamples(monoSamples, level: level)
            }
        }

        engine.prepare()
        try engine.start()

        self.engine = engine
        isRecording = true
    }

    func stopRecording() -> RecordedAudio {
        guard isRecording else {
            return RecordedAudio(samples: [], sampleRate: sampleRate)
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        onLevelChanged?(0)

        return RecordedAudio(
            samples: samples,
            sampleRate: sampleRate
        )
    }

    private func appendSamples(_ newSamples: [Float], level: Double) {
        samples.append(contentsOf: newSamples)
        onLevelChanged?(level)
    }

    nonisolated private static func level(sumSquares: Float, frameCount: Int) -> Double {
        guard frameCount > 0 else { return 0 }

        let rms = sqrt(sumSquares / Float(frameCount))
        let noiseFloor: Float = 0.018
        let usableRange: Float = 0.16
        let gated = max(0, rms - noiseFloor)
        return Double(min(1, gated / usableRange))
    }

}

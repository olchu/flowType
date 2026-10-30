import AudioToolbox
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
    private var isRecording: Bool { engine != nil }
    /// The level of each buffer, and the shape of its spectrum; see
    /// SpectrumAnalyzer.
    var onLevelChanged: ((Double, SpectrumBands) -> Void)?

    /// Records from `inputDeviceID`, or from the system's microphone.
    func startRecording(inputDeviceID: AudioDeviceID?) throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if let inputDeviceID {
            Self.select(inputDeviceID, for: inputNode)
        }
        // Not outputFormat: it stays on the system's microphone after
        // selecting another, and a tap in a rate the device doesn't run at
        // gets no audio at all.
        let format = inputNode.inputFormat(forBus: 0)

        guard format.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        samples.removeAll(keepingCapacity: true)
        sampleRate = format.sampleRate
        let analyzer = SpectrumAnalyzer(sampleRate: format.sampleRate)

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
            let bands = analyzer?.bands(of: monoSamples) ?? .zero

            Task { @MainActor in
                self?.appendSamples(monoSamples, level: level, bands: bands)
            }
        }

        engine.prepare()
        try engine.start()

        self.engine = engine
    }

    func stopRecording() -> RecordedAudio {
        guard isRecording else {
            return RecordedAudio(samples: [], sampleRate: sampleRate)
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onLevelChanged?(0, .zero)

        // Resampled once here so the VAD and the decoders all get audio at
        // their native rate instead of each converting the whole recording.
        return RecordedAudio(samples: samples, sampleRate: sampleRate)
            .resampled(to: RecordedAudio.speechSampleRate)
    }

    private func appendSamples(_ newSamples: [Float], level: Double, bands: SpectrumBands) {
        samples.append(contentsOf: newSamples)
        onLevelChanged?(level, bands)
    }

    /// A device that can't be selected leaves the node on the system's
    /// microphone, which beats not recording at all.
    private static func select(_ deviceID: AudioDeviceID, for inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else { return }
        var deviceID = deviceID
        AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    nonisolated private static func level(sumSquares: Float, frameCount: Int) -> Double {
        guard frameCount > 0 else { return 0 }

        let rms = sqrt(sumSquares / Float(frameCount))
        let noiseFloor: Float = 0.018
        let usableRange: Float = 0.16
        let gated = max(0, rms - noiseFloor)
        // Loudness is perceived roughly logarithmically; the curve lifts quiet
        // speech while silence below the noise floor stays at zero.
        return pow(Double(min(1, gated / usableRange)), 0.6)
    }

}

import AVFoundation
import Foundation

@MainActor
final class AudioRecorderService {
    enum AudioRecorderError: LocalizedError {
        case noInputDevice
        case alreadyRecording
        case wavBufferCreationFailed

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                "No microphone input device is available."
            case .alreadyRecording:
                "Recording is already in progress."
            case .wavBufferCreationFailed:
                "Could not prepare recorded audio for transcription."
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
            Task { @MainActor in
                self?.appendSamples(from: buffer)
            }
        }

        engine.prepare()
        try engine.start()

        self.engine = engine
        isRecording = true
    }

    func stopRecording() -> RecordedAudio {
        guard isRecording else {
            return RecordedAudio(samples: [], sampleRate: sampleRate, temporaryFileURL: nil)
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        onLevelChanged?(0)

        return RecordedAudio(
            samples: samples,
            sampleRate: sampleRate,
            temporaryFileURL: try? writeTemporaryWAV(samples: samples, sampleRate: sampleRate)
        )
    }

    private func appendSamples(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for frame in 0..<frameCount {
            var sample: Float = 0

            for channel in 0..<channelCount {
                sample += channelData[channel][frame]
            }

            let monoSample = sample / Float(channelCount)
            samples.append(monoSample)
        }

        onLevelChanged?(level(from: buffer))
    }

    private func level(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0

        for frame in 0..<frameCount {
            var sample: Float = 0

            for channel in 0..<channelCount {
                sample += channelData[channel][frame]
            }

            let monoSample = sample / Float(channelCount)
            sumSquares += monoSample * monoSample
        }

        guard frameCount > 0 else { return 0 }

        let rms = sqrt(sumSquares / Float(frameCount))
        let noiseFloor: Float = 0.018
        let usableRange: Float = 0.16
        let gated = max(0, rms - noiseFloor)
        return Double(min(1, gated / usableRange))
    }

    private func writeTemporaryWAV(samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowtype-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AudioRecorderError.wavBufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData?[0]

        for index in samples.indices {
            channel?[index] = samples[index]
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

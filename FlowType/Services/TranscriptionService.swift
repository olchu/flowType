import Foundation
import WhisperKit

@MainActor
final class TranscriptionService {
    struct StreamingTranscriptionResult {
        /// Everything the stream produced, including unconfirmed text.
        let transcript: String
        /// Text of the segments WhisperKit confirmed; it no longer changes.
        let confirmedTranscript: String
        /// Where the confirmed text ends on the stream audio timeline.
        let confirmedEndSeconds: TimeInterval
        /// Microphone audio the stream decoded, on the same timeline as the
        /// segment timestamps.
        let audio: RecordedAudio

        /// Audio that the confirmed text does not cover yet. It starts on a
        /// Whisper segment boundary, so decoding it never starts mid-word and
        /// its text can be appended to `confirmedTranscript` without fuzzy
        /// overlap matching.
        var unconfirmedAudio: RecordedAudio {
            audio.suffix(from: confirmedEndSeconds)
        }
    }

    enum TranscriptionError: LocalizedError {
        case emptyRecording
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .emptyRecording:
                "No audio was captured."
            case .emptyTranscript:
                "The speech model did not return any text."
            }
        }
    }

    private var pipeline: WhisperKit?
    private var loadedModel: TranscriptionModel?
    private var streamTranscriber: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?
    private let streamSnapshot = StreamSnapshotStore()
    private let parakeet = ParakeetTranscriber()
    private let gigaAM = GigaAMTranscriber()

    func prewarm(model: TranscriptionModel, onProgress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        // Only one speech model stays in memory.
        if model.engine != .whisperKit {
            pipeline = nil
            loadedModel = nil
        }
        if model.engine != .parakeet {
            await parakeet.unload()
        }
        if model.engine != .gigaAM {
            await gigaAM.unload()
        }

        switch model.engine {
        case .whisperKit:
            _ = try await pipeline(for: model, shouldPrewarm: true, onProgress: onProgress)
        case .parakeet:
            onProgress?(0.5, "Loading Parakeet...")
            try await parakeet.prewarm()
            onProgress?(1, "Model ready")
        case .gigaAM:
            onProgress?(0.5, "Loading GigaAM...")
            try await gigaAM.prewarm()
            onProgress?(1, "Model ready")
        }
    }

    func transcribe(
        _ audio: RecordedAudio,
        language: TranscriptionLanguage,
        model: TranscriptionModel
    ) async throws -> String {
        guard !audio.isEmpty else {
            throw TranscriptionError.emptyRecording
        }

        let transcript: String
        switch model.engine {
        case .parakeet:
            transcript = TranscriptText.clean(
                try await parakeet.transcribe(
                    audio.samples(resampledTo: RecordedAudio.speechSampleRate),
                    languageCode: language.whisperKitCode
                )
            )
        case .gigaAM:
            // Russian only, so the language setting doesn't apply.
            transcript = TranscriptText.clean(
                try await gigaAM.transcribe(audio.samples(resampledTo: RecordedAudio.speechSampleRate))
            )
        case .whisperKit:
            let pipeline = try await pipeline(for: model, shouldPrewarm: false)
            let results = try await pipeline.transcribe(
                audioArray: audio.samples(resampledTo: Double(WhisperKit.sampleRate)),
                decodeOptions: Self.decodingOptions(for: language)
            )
            transcript = Self.text(of: results.flatMap(\.segments))
        }

        guard !transcript.isEmpty else {
            throw TranscriptionError.emptyTranscript
        }

        return transcript
    }

    func startStreamingTranscription(
        language: TranscriptionLanguage,
        model: TranscriptionModel
    ) async throws {
        await stopStreamingTranscription()
        streamSnapshot.reset()

        guard model.supportsStreaming else { return }

        let pipeline = try await pipeline(for: model, shouldPrewarm: false)
        // Cancelled dictations must not open a stream after they were stopped;
        // nothing would stop it until the next dictation.
        guard !Task.isCancelled else { return }
        guard let tokenizer = pipeline.tokenizer else {
            throw WhisperError.tokenizerUnavailable()
        }

        var options = Self.decodingOptions(for: language)
        options.wordTimestamps = true
        options.concurrentWorkerCount = 1

        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipeline.audioEncoder,
            featureExtractor: pipeline.featureExtractor,
            segmentSeeker: pipeline.segmentSeeker,
            textDecoder: pipeline.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipeline.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 1
        ) { [streamSnapshot] _, newState in
            // Only stored here: the text is merged once, when the dictation
            // stops, rather than on every state change.
            streamSnapshot.update(StreamSnapshot(
                confirmedSegments: newState.confirmedSegments,
                unconfirmedSegments: newState.unconfirmedSegments,
                currentText: newState.currentText,
                confirmedEndSeconds: TimeInterval(newState.lastConfirmedSegmentEndSeconds)
            ))
        }

        streamTranscriber = transcriber
        streamTask = Task { [streamSnapshot] in
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                // A failed stream leaves no text, so the recording is decoded
                // in full when the dictation stops.
                streamSnapshot.reset()
            }
        }
    }

    @discardableResult
    func stopStreamingTranscription() async -> StreamingTranscriptionResult {
        // Without a live stream the audio processor still holds the previous
        // dictation's samples, which must not be mistaken for this one.
        let hadStream = streamTranscriber != nil
        await streamTranscriber?.stopStreamTranscription()
        // Everything after the last confirmed segment is decoded again when the
        // dictation is finalized, so waiting for an in-flight streaming pass
        // would only delay the paste.
        streamTask?.cancel()
        await streamTask?.value
        streamTask = nil
        streamTranscriber = nil

        let snapshot = streamSnapshot.current()
        let audioSamples = hadStream ? pipeline.map { Array($0.audioProcessor.audioSamples) } ?? [] : []
        streamSnapshot.reset()

        return StreamingTranscriptionResult(
            transcript: Self.transcript(from: snapshot).trimmingCharacters(in: .whitespacesAndNewlines),
            confirmedTranscript: Self.text(of: snapshot.confirmedSegments),
            confirmedEndSeconds: snapshot.confirmedEndSeconds,
            audio: RecordedAudio(samples: audioSamples, sampleRate: Double(WhisperKit.sampleRate))
        )
    }

    private func pipeline(
        for model: TranscriptionModel,
        shouldPrewarm: Bool,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> WhisperKit {
        if let pipeline, loadedModel == model {
            return pipeline
        }

        if let onProgress {
            let tracker = LoadingStageTracker()
            Logging.shared.loggingCallback = { message in
                if let (progress, label) = tracker.process(message: message) {
                    onProgress(progress, label)
                }
            }
        }

        defer {
            if onProgress != nil {
                Logging.shared.logLevel = .error
                Logging.shared.loggingCallback = nil
            }
        }

        let config = WhisperKitConfig(
            model: model.whisperKitIdentifier ?? "",
            modelRepo: TranscriptionModel.repository,
            verbose: onProgress != nil,
            logLevel: .debug,
            prewarm: shouldPrewarm,
            load: true,
            download: true
        )
        let pipeline = try await WhisperKit(config)

        self.pipeline = pipeline
        loadedModel = model
        return pipeline
    }

    func resetLoadedModel(ifMatching model: TranscriptionModel) async {
        switch model.engine {
        case .parakeet:
            await parakeet.unload()
        case .gigaAM:
            await gigaAM.unload()
        case .whisperKit:
            break
        }
        guard loadedModel == model else { return }
        pipeline = nil
        loadedModel = nil
    }

    nonisolated private static func decodingOptions(for language: TranscriptionLanguage) -> DecodingOptions {
        DecodingOptions(
            language: language.whisperKitCode,
            detectLanguage: language == .auto,
            skipSpecialTokens: true
        )
    }

    nonisolated private static func transcript(from snapshot: StreamSnapshot) -> String {
        let segmentText = (snapshot.confirmedSegments + snapshot.unconfirmedSegments)
            .map(\.text)
            .filter { !TranscriptText.isLikelyHallucination($0) }
        let currentText = snapshot.currentText == "Waiting for speech..." ? "" : snapshot.currentText

        return TranscriptText.merged(segmentText + [currentText])
    }

    nonisolated private static func text(of segments: [TranscriptionSegment]) -> String {
        segments
            .map(\.text)
            .filter { !TranscriptText.isLikelyHallucination($0) }
            .map(TranscriptText.clean)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

}

// Latest stream state. Written from WhisperKit's state callback, read on the
// main actor when the dictation stops.
private nonisolated struct StreamSnapshot: Sendable {
    var confirmedSegments: [TranscriptionSegment] = []
    var unconfirmedSegments: [TranscriptionSegment] = []
    var currentText = ""
    var confirmedEndSeconds: TimeInterval = 0
}

private final class StreamSnapshotStore: @unchecked Sendable {
    nonisolated(unsafe) private var snapshot = StreamSnapshot()
    private let lock = NSLock()

    nonisolated func update(_ newSnapshot: StreamSnapshot) {
        lock.withLock { snapshot = newSnapshot }
    }

    nonisolated func current() -> StreamSnapshot {
        lock.withLock { snapshot }
    }

    nonisolated func reset() {
        lock.withLock { snapshot = StreamSnapshot() }
    }
}

// Sequentially matches WhisperKit loading log messages to progress values.
// Thread-safe: can be called from any thread.
private final class LoadingStageTracker: @unchecked Sendable {
    private struct Stage: Sendable {
        let keyword: String
        let progress: Double
        let label: String
    }

    // Two-pass loading: prewarm (specialization) then full load.
    // Stage ordering must match WhisperKit's log emission order exactly.
    private let stages: [Stage] = [
        Stage(keyword: "Prewarming models",        progress: 0.05, label: "Specializing for device..."),
        Stage(keyword: "Loading feature extractor", progress: 0.10, label: "Loading feature extractor..."),
        Stage(keyword: "Loaded feature extractor",  progress: 0.22, label: "Feature extractor specialized"),
        Stage(keyword: "Loading text decoder",      progress: 0.24, label: "Loading text decoder..."),
        Stage(keyword: "Loaded text decoder",       progress: 0.38, label: "Text decoder specialized"),
        Stage(keyword: "Loading audio encoder",     progress: 0.40, label: "Loading audio encoder..."),
        Stage(keyword: "Loaded audio encoder",      progress: 0.48, label: "Audio encoder specialized"),
        Stage(keyword: "Loading models",            progress: 0.50, label: "Loading full model..."),
        Stage(keyword: "Loading feature extractor", progress: 0.55, label: "Loading feature extractor..."),
        Stage(keyword: "Loaded feature extractor",  progress: 0.67, label: "Feature extractor loaded"),
        Stage(keyword: "Loading text decoder",      progress: 0.69, label: "Loading text decoder..."),
        Stage(keyword: "Loaded text decoder",       progress: 0.80, label: "Text decoder loaded"),
        Stage(keyword: "Loading audio encoder",     progress: 0.82, label: "Loading audio encoder..."),
        Stage(keyword: "Loaded audio encoder",      progress: 0.93, label: "Audio encoder loaded"),
        Stage(keyword: "Loaded models for whisper", progress: 1.00, label: "Model ready"),
    ]

    nonisolated(unsafe) private var currentIndex = 0
    private let lock = NSLock()

    nonisolated func process(message: String) -> (Double, String)? {
        lock.lock()
        defer { lock.unlock() }

        guard currentIndex < stages.count else { return nil }
        let stage = stages[currentIndex]
        guard message.contains(stage.keyword) else { return nil }
        currentIndex += 1
        return (stage.progress, stage.label)
    }
}

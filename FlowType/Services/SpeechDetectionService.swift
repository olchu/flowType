import Foundation
import FluidAudio

/// Silero VAD (1 MB, Core ML) deciding whether a recording holds speech and
/// where it starts and ends. Whisper fills silence with invented text, so the
/// silent edges are cut off before decoding and silent recordings are dropped.
///
/// Kept in its own file: FluidAudio and WhisperKit export clashing type names.
actor SpeechDetectionService {
    enum Detection: Equatable {
        /// Silero is still loading; callers fall back to the energy check.
        case unavailable
        case noSpeech
        /// Speech bounds in seconds, padded so soft word edges are kept.
        case speech(start: TimeInterval, end: TimeInterval)
    }

    private var manager: VadManager?
    private var loadTask: Task<VadManager, Error>?

    // Silero's reference threshold. FluidAudio defaults to a stricter 0.85,
    // which can miss quiet dictation, and a missed dictation is worse than a
    // decoded pause.
    private static let config = VadConfig(defaultThreshold: 0.5)

    // FluidAudio asserts speechPadding <= minSpeechDuration (a debug build
    // traps on it), so the rest of the margin is added in `detect`.
    private static let segmentation = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.4,
        maxSpeechDuration: 30,
        speechPadding: 0.1
    )

    /// Extra margin around the detected speech, on top of Silero's padding,
    /// so soft word onsets and endings are not cut.
    private static let extraPadding: TimeInterval = 0.2

    func prewarm() async {
        _ = try? await loadedManager()
    }

    func detect(in audio: RecordedAudio) async -> Detection {
        // Never delay a dictation on the model download; it is ready next time.
        guard let manager else {
            Task { await prewarm() }
            return .unavailable
        }

        let samples = audio.samples(resampledTo: Double(VadManager.sampleRate))
        guard !samples.isEmpty else { return .noSpeech }

        do {
            let segments = try await manager.segmentSpeech(samples, config: Self.segmentation)
            guard let first = segments.first, let last = segments.last else {
                return .noSpeech
            }
            return .speech(
                start: max(0, first.startTime - Self.extraPadding),
                end: min(audio.duration, last.endTime + Self.extraPadding)
            )
        } catch {
            return .unavailable
        }
    }

    private func loadedManager() async throws -> VadManager {
        if let manager {
            return manager
        }
        if let loadTask {
            return try await loadTask.value
        }

        let task = Task { try await VadManager(config: Self.config) }
        loadTask = task
        do {
            let manager = try await task.value
            self.manager = manager
            return manager
        } catch {
            loadTask = nil
            throw error
        }
    }
}

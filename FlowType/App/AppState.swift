import AppKit
import AVFoundation
import Combine
import Foundation
import os

@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .ready {
        didSet {
            updateFloatingIndicator()
        }
    }
    @Published var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            settingsStorageService.save(settings)
            if settings.profile != oldValue.profile {
                prewarmCurrentModel()
            }
            if settings.cleanupMode == .localLLM
                && (oldValue.cleanupMode != .localLLM || oldValue.cleanupModel != settings.cleanupModel) {
                prewarmTranscriptCleanupModel()
            }
        }
    }
    @Published var lastErrorMessage: String?
    @Published private(set) var isHotkeyRunning = false
    @Published private(set) var hotkeyStatusMessage = "Waiting for Accessibility permission."
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var microphonePermission: PermissionStatus = .unknown
    @Published private(set) var isModelWarmingUp = false {
        didSet {
            updateFloatingIndicator()
        }
    }
    @Published private(set) var modelWarmupMessage = "Model is not loaded yet."
    @Published private(set) var modelLoadingProgress: Double = 0
    @Published private(set) var modelStorageStates: [TranscriptionModel: ModelStorageState] = [:]
    @Published private(set) var resourceUsage = ProcessResourceUsage()
    @Published private(set) var hasCompletedOnboarding = false
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusMessage = "Disabled"
    @Published private(set) var isCleanupModelWarmingUp = false
    @Published private(set) var cleanupModelMessage = "Local LLM cleanup is not loaded."

    private let audioRecorder = AudioRecorderService()
    private let hotkeyService = HotkeyService()
    private let permissionsService = PermissionsService()
    private let transcriptionService = TranscriptionService()
    private let transcriptCleanupService = TranscriptCleanupService()
    private let speechDetector = SpeechDetectionService()
    private let pasteService = PasteService()
    private let modelStorageService = ModelStorageService()
    private let settingsStorageService = SettingsStorageService()
    private let resourceMonitorService = ProcessResourceMonitorService()
    private let loginItemService = LoginItemService()
    private let floatingIndicatorController = FloatingIndicatorController()
    private let feedbackSoundPlayer = FeedbackSoundPlayer()
    private let finalTailSilenceMargin: TimeInterval = 0.5
    private lazy var onboardingWindowController = OnboardingWindowController(appState: self)
    private var dictationTargetApplication: NSRunningApplication?
    private var resourceUsageTask: Task<Void, Never>?
    private var streamingTranscriptionTask: Task<Void, Never>?
    private var audioLevel: Double = 0
    private var smoothedAudioLevel: Double = 0

    init() {
        settings = settingsStorageService.load()
        hasCompletedOnboarding = settingsStorageService.hasCompletedOnboarding()
        audioRecorder.onLevelChanged = { [weak self] level in
            guard let self else { return }
            updateAudioLevel(level)
        }

        refreshPermissions()
        refreshLaunchAtLoginStatus()
        refreshModelStorageStates()
        configureHotkey()
        prewarmCurrentModel()
        Task { [speechDetector] in await speechDetector.prewarm() }
        if settings.cleanupMode == .localLLM {
            prewarmTranscriptCleanupModel()
        }
        startResourceUsageMonitoring()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.showOnboardingIfNeeded()
        }
    }

    deinit {
        resourceUsageTask?.cancel()
        streamingTranscriptionTask?.cancel()
    }

    var isReadyForUse: Bool {
        microphonePermission.isGranted
            && hasAccessibilityPermission
            && isHotkeyRunning
            && !isModelWarmingUp
            && selectedModelStorageState == .downloaded
            && status != .error
    }

    var menuStatusText: String {
        if isReadyForUse {
            return "Ready to use"
        }

        switch status {
        case .recording, .transcribing:
            return status.rawValue
        case .error:
            return "Needs attention"
        case .ready:
            return isModelWarmingUp ? "Preparing model" : "Not ready"
        }
    }

    var canStartRecording: Bool {
        (status == .ready || status == .error)
            && microphonePermission.isGranted
            && !isModelWarmingUp
            && selectedModelStorageState == .downloaded
    }

    var canStopRecording: Bool {
        status == .recording
    }

    var selectedModelStorageState: ModelStorageState {
        storageState(of: settings.profile.model)
    }

    func storageState(of model: TranscriptionModel) -> ModelStorageState {
        modelStorageStates[model] ?? .notDownloaded
    }

    func startDictation() {
        guard canStartRecording else { return }

        lastErrorMessage = nil
        audioLevel = 0
        smoothedAudioLevel = 0

        let timing = DictationTiming()
        timing.mark("start requested")

        do {
            try audioRecorder.startRecording()
            timing.mark("audio recording started")
        } catch {
            showError(error)
            return
        }

        dictationTargetApplication = NSWorkspace.shared.frontmostApplication
        status = .recording
        feedbackSoundPlayer.play(.recordingStarted)

        streamingTranscriptionTask?.cancel()
        streamingTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await transcriptionService.startStreamingTranscription(
                    language: settings.language,
                    model: settings.profile.model
                )
            } catch {
                _ = audioRecorder.stopRecording()
                showError(error)
            }
        }
    }

    func finishDictation() {
        guard canStopRecording else { return }

        audioLevel = 0
        smoothedAudioLevel = 0
        status = .transcribing
        feedbackSoundPlayer.play(.recordingStopped)

        Task {
            let timing = DictationTiming()
            timing.mark("finish requested")
            let recordedAudio = audioRecorder.stopRecording()
            timing.mark("audio stopped duration=\(formattedSeconds(recordedAudio.duration))s samples=\(recordedAudio.samples.count)")

            let streamingResult = await transcriptionService.stopStreamingTranscription()
            timing.mark(
                "stream stopped textChars=\(streamingResult.transcript.count) confirmedChars=\(streamingResult.confirmedTranscript.count) confirmedEnd=\(formattedSeconds(streamingResult.confirmedEndSeconds))s streamAudio=\(formattedSeconds(streamingResult.audio.duration))s"
            )

            streamingTranscriptionTask?.cancel()
            streamingTranscriptionTask = nil

            let rawTranscript = await finalTranscript(
                from: recordedAudio,
                streamingResult: streamingResult,
                timing: timing
            )
            timing.mark("final transcript ready chars=\(rawTranscript.count)")

            let cleanupResult = await transcriptCleanupService.clean(
                rawTranscript,
                mode: settings.cleanupMode,
                model: settings.cleanupModel
            )
            let transcript = cleanupResult.text
            timing.mark(
                "cleanup completed mode=\(settings.cleanupMode.rawValue) model=\(settings.cleanupModel.rawValue) decision=\(cleanupResult.decision) rawChars=\(rawTranscript.count) chars=\(transcript.count)"
            )

            guard !transcript.isEmpty else {
                status = .ready
                timing.finish("empty transcript")
                return
            }

            if settings.autoPaste {
                do {
                    try await pasteService.pasteText(
                        transcript,
                        restoreClipboard: settings.restoreClipboard,
                        into: dictationTargetApplication
                    )
                    timing.mark("paste completed")
                    feedbackSoundPlayer.play(.pasted)
                } catch {
                    showError(error)
                    timing.finish("paste failed")
                    return
                }
            }

            status = .ready
            floatingIndicatorController.showPasted()
            timing.finish("ready")
        }
    }

    private func finalTranscript(
        from recordedAudio: RecordedAudio,
        streamingResult: TranscriptionService.StreamingTranscriptionResult,
        timing: DictationTiming? = nil
    ) async -> String {
        let streamingTranscript = streamingResult.transcript

        // Silero decides whether there was any speech; the energy check stands
        // in while the VAD model is still loading. Only the trailing silence is
        // cut, and only for Whisper, which invents text for it. The start is
        // never cut: Silero works in 256 ms steps, so its speech start can
        // clip a first syllable, and dropping it would not speed anything up.
        let speechAudio: RecordedAudio
        switch await speechDetector.detect(in: recordedAudio) {
        case .noSpeech:
            timing?.mark("speech gate skipped final decode vad=silero")
            return ""
        case .unavailable:
            guard recordedAudio.containsLikelySpeech else {
                timing?.mark("speech gate skipped final decode vad=energy")
                return ""
            }
            speechAudio = recordedAudio
        case .speech(let start, let end):
            speechAudio = settings.profile.model.trimsTrailingSilence
                ? recordedAudio.prefix(seconds: end)
                : recordedAudio
            timing?.mark(
                "vad speech=\(formattedSeconds(start))-\(formattedSeconds(end))s of \(formattedSeconds(recordedAudio.duration))s"
            )
        }

        do {
            timing?.mark("finalization mode=\(settings.finalizationMode.rawValue)")

            if !settings.profile.model.supportsStreaming {
                return try await fullTranscript(of: speechAudio, reason: "no-stream-model", timing: timing)
            }

            guard !streamingTranscript.isEmpty else {
                return try await fullTranscript(of: speechAudio, reason: "empty-stream", timing: timing)
            }

            switch settings.finalizationMode {
            case .fullRecording:
                return try await fullTranscript(of: speechAudio, reason: "baseline-mode", timing: timing)

            case .streamOnly:
                timing?.mark("final decode skipped reason=stream-only")
                return streamingTranscript

            case .streamTail:
                return try await streamTailTranscript(
                    speechAudio: speechAudio,
                    streamingResult: streamingResult,
                    timing: timing
                )
            }
        } catch {
            timing?.mark("final decode failed fallback=stream error=\(error.localizedDescription)")
            return streamingTranscript
        }
    }

    private func fullTranscript(of audio: RecordedAudio, reason: String, timing: DictationTiming?) async throws -> String {
        timing?.mark("full decode started reason=\(reason) window=\(formattedSeconds(audio.duration))s")
        let transcript = try await transcriptionService.transcribe(
            audio,
            language: settings.language,
            model: settings.profile.model
        )
        timing?.mark("full decode completed chars=\(transcript.count)")
        return transcript
    }

    /// Keeps the text WhisperKit already confirmed and decodes only the audio
    /// after the last confirmed segment. That boundary is a segment edge on the
    /// stream's own timeline, so the tail never starts mid-word and its text is
    /// appended as is. A fixed-length suffix of the recording used to cut words
    /// in half ("Убыстрить" -> "Быстрится"), and fuzzy merging then failed to
    /// recognize the garbled repeat and appended it a second time.
    private func streamTailTranscript(
        speechAudio: RecordedAudio,
        streamingResult: TranscriptionService.StreamingTranscriptionResult,
        timing: DictationTiming?
    ) async throws -> String {
        let confirmedTranscript = streamingResult.confirmedTranscript

        guard !confirmedTranscript.isEmpty, !streamingResult.audio.isEmpty else {
            // Nothing confirmed yet: one decode of the whole recording is as
            // fast as a tail decode (the encoder always sees a 30 s window)
            // and the recorder started before the stream, so it misses nothing.
            return try await fullTranscript(of: speechAudio, reason: "nothing-confirmed", timing: timing)
        }

        // Trailing silence is where Whisper hallucinates, so stop shortly after
        // the last speech. The tail start stays on the segment boundary.
        let tailAudio = streamingResult.unconfirmedAudio
        let speechEnd: TimeInterval
        switch await speechDetector.detect(in: tailAudio) {
        case .noSpeech:
            timing?.mark("tail decode skipped reason=no-speech vad=silero tail=\(formattedSeconds(tailAudio.duration))s")
            return confirmedTranscript
        case .speech(_, let end):
            speechEnd = end
        case .unavailable:
            guard let energySpeechEnd = tailAudio.lastSpeechEnd(noiseFloor: streamingResult.audio.noiseFloor) else {
                timing?.mark("tail decode skipped reason=no-speech vad=energy tail=\(formattedSeconds(tailAudio.duration))s")
                return confirmedTranscript
            }
            // The margin keeps quiet word endings the energy check misses.
            speechEnd = energySpeechEnd + finalTailSilenceMargin
        }

        let trimmedTail = tailAudio.prefix(seconds: speechEnd)
        timing?.mark(
            "tail decode started from=\(formattedSeconds(streamingResult.confirmedEndSeconds))s window=\(formattedSeconds(trimmedTail.duration))s"
        )

        let tailTranscript: String
        do {
            tailTranscript = try await transcriptionService.transcribe(
                trimmedTail,
                language: settings.language,
                model: settings.profile.model
            )
        } catch TranscriptionService.TranscriptionError.emptyTranscript {
            tailTranscript = ""
        }
        timing?.mark("tail decode completed chars=\(tailTranscript.count)")

        return TranscriptText.joined(prefix: confirmedTranscript, continuation: tailTranscript)
    }

    private func updateAudioLevel(_ level: Double) {
        let clampedLevel = min(1, max(0, level))
        let smoothing = clampedLevel > smoothedAudioLevel ? 0.6 : 0.3
        smoothedAudioLevel += (clampedLevel - smoothedAudioLevel) * smoothing

        guard abs(audioLevel - smoothedAudioLevel) >= 0.01 || smoothedAudioLevel == 0 else {
            return
        }

        audioLevel = smoothedAudioLevel
        updateFloatingIndicator()
    }

    func clearError() {
        lastErrorMessage = nil
        status = .ready
    }

    func prewarmCurrentModel() {
        guard !isModelWarmingUp else { return }

        let model = settings.profile.model
        guard modelStorageStates[model] == .downloaded else {
            modelWarmupMessage = "\(model.rawValue) is not downloaded."
            return
        }

        isModelWarmingUp = true
        modelLoadingProgress = 0
        modelWarmupMessage = "Loading \(settings.profile.rawValue) (\(model.rawValue))..."

        Task {
            do {
                try await transcriptionService.prewarm(model: model) { [weak self] progress, label in
                    Task { @MainActor [weak self] in
                        self?.modelLoadingProgress = progress
                        self?.modelWarmupMessage = label
                    }
                }
                modelLoadingProgress = 1
                modelWarmupMessage = "\(model.rawValue) is ready."
                refreshModelStorageStates()
            } catch {
                modelWarmupMessage = "Could not load \(model.rawValue)."
                showError(error)
            }

            isModelWarmingUp = false
        }
    }

    func prewarmTranscriptCleanupModel() {
        guard settings.cleanupMode == .localLLM else {
            cleanupModelMessage = "Local LLM cleanup is disabled."
            return
        }
        let model = settings.cleanupModel
        isCleanupModelWarmingUp = true
        cleanupModelMessage = "Loading \(model.rawValue) (downloads on first use)..."

        Task {
            do {
                try await transcriptCleanupService.prewarmLocalLLM(model: model)
                // A newer selection may have started loading meanwhile.
                guard settings.cleanupModel == model else { return }
                cleanupModelMessage = "\(model.rawValue) is ready."
            } catch {
                guard settings.cleanupModel == model else { return }
                cleanupModelMessage = "Could not load \(model.rawValue)."
                showError(error)
            }

            isCleanupModelWarmingUp = false
        }
    }

    func download(_ model: TranscriptionModel) {
        modelStorageStates[model] = .downloading

        Task {
            do {
                try await modelStorageService.download(model)
                modelStorageStates[model] = .downloaded
                if model == settings.profile.model {
                    prewarmCurrentModel()
                }
            } catch {
                modelStorageStates[model] = .error(error.localizedDescription)
            }
        }
    }

    func finishOnboarding() {
        hasCompletedOnboarding = true
        settingsStorageService.setOnboardingCompleted(true)
        onboardingWindowController.close()
    }

    func delete(_ model: TranscriptionModel) {
        modelStorageStates[model] = .deleting

        Task {
            do {
                try modelStorageService.delete(model)
                await transcriptionService.resetLoadedModel(ifMatching: model)
                modelStorageStates[model] = .notDownloaded
                if model == settings.profile.model {
                    isModelWarmingUp = false
                    modelWarmupMessage = "\(model.rawValue) was deleted."
                }
            } catch {
                modelStorageStates[model] = .error(error.localizedDescription)
            }
        }
    }

    func restartHotkey() {
        refreshPermissions()
        hotkeyService.stop()
        configureHotkey()
    }

    func requestAccessibilityPermission() {
        permissionsService.promptForAccessibilityPermission()
        permissionsService.openAccessibilitySettings()
        refreshPermissions()
    }

    func requestMicrophonePermission() {
        Task {
            _ = await permissionsService.requestMicrophonePermission()
            refreshPermissions()
        }
    }

    func refreshPermissions() {
        hasAccessibilityPermission = permissionsService.hasAccessibilityPermission
        microphonePermission = PermissionStatus(permissionsService.microphoneAuthorizationStatus)
    }

    func refreshModelStorageStates() {
        for model in TranscriptionModel.allCases {
            modelStorageStates[model] = modelStorageService.isDownloaded(model)
                ? .downloaded
                : .notDownloaded
        }
    }

    func refreshResourceUsage() {
        resourceUsage = resourceMonitorService.currentUsage()
    }

    func refreshLaunchAtLoginStatus() {
        isLaunchAtLoginEnabled = loginItemService.isEnabled
        launchAtLoginStatusMessage = loginItemService.statusDescription
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            try loginItemService.setEnabled(isEnabled)
        } catch {
            showError(error)
        }
        refreshLaunchAtLoginStatus()
    }

    func resetSettingsToDefaults() {
        settingsStorageService.reset()
        settings = AppSettings()
    }

    func showOnboardingIfNeeded() {
        guard !hasCompletedOnboarding else { return }
        guard selectedModelStorageState != .downloaded else {
            finishOnboarding()
            return
        }

        onboardingWindowController.show()
    }

    private func configureHotkey() {
        guard hasAccessibilityPermission else {
            isHotkeyRunning = false
            hotkeyStatusMessage = "Waiting for Accessibility permission."
            return
        }

        hotkeyService.onKeyDown = { [weak self] in
            self?.startDictation()
        }

        hotkeyService.onKeyUp = { [weak self] in
            self?.finishDictation()
        }

        do {
            try hotkeyService.start()
            isHotkeyRunning = true
            hotkeyStatusMessage = "Running"
        } catch {
            isHotkeyRunning = false
            hotkeyStatusMessage = error.localizedDescription
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        status = .error
    }

    private func startResourceUsageMonitoring() {
        refreshResourceUsage()
        resourceUsageTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refreshResourceUsage()
            }
        }
    }

    private func updateFloatingIndicator() {
        floatingIndicatorController.update(
            for: status,
            isModelLoading: isModelWarmingUp,
            audioLevel: Self.gatedLevel(audioLevel, sensitivity: settings.microphoneSensitivity),
            style: settings.indicatorStyle
        )
    }

    /// Higher sensitivity lowers the level below which the bars stay idle.
    private static func gatedLevel(_ level: Double, sensitivity: Double) -> Double {
        let threshold = 0.09 - min(max(sensitivity, 0), 1) * 0.08
        return max(0, (level - threshold) / max(0.01, 1 - threshold))
    }
}

private enum FeedbackSound {
    case recordingStarted
    case recordingStopped
    case pasted

    /// WAV files in FlowType/Sounds, bundled as resources.
    var fileName: String {
        switch self {
        case .recordingStarted:
            "record_start"
        case .recordingStopped:
            "record_stop"
        case .pasted:
            "pasted"
        }
    }

    var volume: Float {
        switch self {
        case .recordingStarted, .recordingStopped:
            0.35
        case .pasted:
            0.45
        }
    }
}

/// Preloaded players, so cues start without a delay. A new cue fades out
/// whatever is still ringing: with fast transcription the stop and paste
/// sounds would otherwise overlap.
@MainActor
private final class FeedbackSoundPlayer {
    private static let handoffFade: TimeInterval = 0.12

    private var players: [FeedbackSound: AVAudioPlayer] = [:]

    init() {
        for sound in [FeedbackSound.recordingStarted, .recordingStopped, .pasted] {
            guard let url = Bundle.main.url(forResource: sound.fileName, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[sound] = player
        }
    }

    func play(_ sound: FeedbackSound) {
        for (other, player) in players where other != sound && player.isPlaying {
            player.setVolume(0, fadeDuration: Self.handoffFade)
        }

        guard let player = players[sound] else {
            NSSound.beep()
            return
        }
        player.stop()
        player.currentTime = 0
        player.volume = sound.volume
        player.play()
    }
}

private final class DictationTiming {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.ochurkin.FlowType", category: "DictationTiming")
    private let start = ContinuousClock.now
    private var last = ContinuousClock.now

    func mark(_ message: String) {
        let now = ContinuousClock.now
        let total = start.duration(to: now) / .seconds(1)
        let delta = last.duration(to: now) / .seconds(1)
        last = now

        let line = "[FlowTypeTiming] +\(formattedSeconds(delta))s total=\(formattedSeconds(total))s \(message)"
        Self.logger.debug("\(line, privacy: .public)")
    }

    func finish(_ message: String) {
        mark("finished \(message)")
    }
    #else
    func mark(_ message: String) {}
    func finish(_ message: String) {}
    #endif
}

nonisolated private func formattedSeconds(_ seconds: TimeInterval) -> String {
    String(format: "%.3f", seconds)
}

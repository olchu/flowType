import AppKit
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
            settingsStorageService.save(settings)
            updateFloatingIndicator()
            if settings.cleanupMode == .localLLM && oldValue.cleanupMode != .localLLM {
                prewarmTranscriptCleanupModel()
            }
        }
    }
    @Published var lastTranscript = ""
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
    @Published private(set) var audioLevel: Double = 0
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
    private let pasteService = PasteService()
    private let modelStorageService = ModelStorageService()
    private let settingsStorageService = SettingsStorageService()
    private let resourceMonitorService = ProcessResourceMonitorService()
    private let loginItemService = LoginItemService()
    private let floatingIndicatorController = FloatingIndicatorController()
    private let finalTailTranscriptionSeconds: TimeInterval = 3
    private let minimumFinalTailRecordingDuration: TimeInterval = 0.9
    private lazy var onboardingWindowController = OnboardingWindowController(appState: self)
    private var dictationTargetApplication: NSRunningApplication?
    private var resourceUsageTask: Task<Void, Never>?
    private var streamingTranscriptionTask: Task<Void, Never>?
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
            && modelStorageStates[settings.profile.model] == .downloaded
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
            && modelStorageStates[settings.profile.model] == .downloaded
    }

    var canStopRecording: Bool {
        status == .recording
    }

    var selectedModelStorageState: ModelStorageState {
        modelStorageStates[settings.profile.model] ?? .notDownloaded
    }

    func startDictation() {
        guard canStartRecording else { return }

        lastErrorMessage = nil
        lastTranscript = ""
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
        playFeedbackSound(.recordingStarted)

        streamingTranscriptionTask?.cancel()
        streamingTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await transcriptionService.startStreamingTranscription(
                    language: settings.language,
                    model: settings.profile.model
                ) { [weak self] transcript in
                    self?.lastTranscript = transcript
                }
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
        playFeedbackSound(.recordingStopped)

        Task {
            let timing = DictationTiming()
            timing.mark("finish requested")
            let recordedAudio = audioRecorder.stopRecording()
            timing.mark("audio stopped duration=\(Self.formattedSeconds(recordedAudio.duration))s samples=\(recordedAudio.samples.count)")

            let streamingResult = await transcriptionService.stopStreamingTranscription()
            timing.mark(
                "stream stopped textChars=\(streamingResult.transcript.count) covered=\(Self.formattedSeconds(streamingResult.coveredDuration))s"
            )

            streamingTranscriptionTask?.cancel()
            streamingTranscriptionTask = nil

            let rawTranscript = await finalTranscript(
                from: recordedAudio,
                streamingResult: streamingResult,
                timing: timing
            )
            timing.mark("final transcript ready chars=\(rawTranscript.count)")

            let cleanupResult = await transcriptCleanupService.clean(rawTranscript, mode: settings.cleanupMode)
            let transcript = cleanupResult.text
            timing.mark(
                "cleanup completed mode=\(settings.cleanupMode.rawValue) decision=\(cleanupResult.decision) rawChars=\(rawTranscript.count) chars=\(transcript.count)"
            )

            guard !transcript.isEmpty else {
                lastTranscript = ""
                status = .ready
                timing.finish("empty transcript")
                return
            }

            lastTranscript = transcript

            if settings.autoPaste {
                do {
                    try await pasteService.pasteText(
                        transcript,
                        restoreClipboard: settings.restoreClipboard,
                        into: dictationTargetApplication
                    )
                    timing.mark("paste completed")
                    playFeedbackSound(.pasted)
                } catch {
                    showPasteFallback(error)
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

        guard recordedAudio.containsLikelySpeech else {
            timing?.mark("speech gate skipped final decode")
            return streamingTranscript
        }

        do {
            timing?.mark("finalization mode=\(settings.finalizationMode.rawValue)")

            guard !streamingTranscript.isEmpty else {
                timing?.mark("full decode started reason=empty-stream")
                let transcript = try await transcriptionService.transcribe(
                    recordedAudio,
                    language: settings.language,
                    model: settings.profile.model
                )
                timing?.mark("full decode completed chars=\(transcript.count)")
                return transcript
            }

            switch settings.finalizationMode {
            case .fullRecording:
                timing?.mark("full decode started reason=baseline-mode")
                let transcript = try await transcriptionService.transcribe(
                    recordedAudio,
                    language: settings.language,
                    model: settings.profile.model
                )
                timing?.mark("full decode completed chars=\(transcript.count)")
                return transcript

            case .streamOnly:
                timing?.mark("final decode skipped reason=stream-only")
                return streamingTranscript

            case .streamTail:
                break
            }

            guard shouldVerifyFinalTail(
                recordedAudio: recordedAudio,
                streamingResult: streamingResult
            ) else {
                timing?.mark("tail decode skipped")
                return streamingTranscript
            }

            timing?.mark("tail decode started window=\(Self.formattedSeconds(finalTailTranscriptionSeconds))s")
            let tailTranscript = try await transcriptionService.transcribe(
                recordedAudio.suffix(seconds: finalTailTranscriptionSeconds),
                language: settings.language,
                model: settings.profile.model
            )
            timing?.mark("tail decode completed chars=\(tailTranscript.count)")

            // When the recording is no longer than the tail window, the "tail"
            // is a clean decode of the entire dictation, not just its ending.
            // Merging it with the streaming transcript of that same audio is
            // what usually produces the duplicated-last-phrase bug on short
            // dictations: both sides describe the same speech but rarely
            // align word-for-word, so the merge keeps both. The tail decode
            // alone is a strictly better result here, so skip the merge.
            guard recordedAudio.duration > finalTailTranscriptionSeconds else {
                timing?.mark("tail covers full recording, using tail transcript directly")
                return tailTranscript
            }

            let mergeResult = TranscriptText.mergedResult(base: streamingTranscript, tail: tailTranscript)
            timing?.mark("merge completed chars=\(mergeResult.text.count) \(mergeResult.diagnosticDescription)")
            return mergeResult.text
        } catch {
            timing?.mark("final decode failed fallback=stream error=\(error.localizedDescription)")
            return streamingTranscript
        }
    }

    private func shouldVerifyFinalTail(
        recordedAudio: RecordedAudio,
        streamingResult: TranscriptionService.StreamingTranscriptionResult
    ) -> Bool {
        guard recordedAudio.duration >= minimumFinalTailRecordingDuration else {
            return false
        }

        if settings.verifiesFinalTail {
            return true
        }

        // WhisperKit's streaming timestamps can say the tail is covered before
        // the last words are actually present in the emitted text, so verify a
        // short final window by default.
        return !streamingResult.transcript.isEmpty
    }

    private func updateAudioLevel(_ level: Double) {
        let clampedLevel = min(1, max(0, level))
        let smoothing = clampedLevel > smoothedAudioLevel ? 0.42 : 0.18
        smoothedAudioLevel += (clampedLevel - smoothedAudioLevel) * smoothing

        guard abs(audioLevel - smoothedAudioLevel) >= 0.01 || smoothedAudioLevel == 0 else {
            return
        }

        audioLevel = smoothedAudioLevel
        updateFloatingIndicator()
    }

    nonisolated private static func formattedSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
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
        guard !isCleanupModelWarmingUp else { return }

        isCleanupModelWarmingUp = true
        cleanupModelMessage = "Loading Qwen2.5 1.5B cleanup model..."

        Task {
            do {
                try await transcriptCleanupService.prewarmLocalLLM()
                cleanupModelMessage = "Qwen2.5 1.5B cleanup model is ready."
            } catch {
                cleanupModelMessage = "Could not load local cleanup model."
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

    func downloadSelectedModelFromOnboarding() {
        download(settings.profile.model)
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
                transcriptionService.resetLoadedModel(ifMatching: model)
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
        for model in TranscriptionModel.availableModels {
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
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            lastErrorMessage = error.localizedDescription
            status = .error
        }
    }

    func resetSettingsToDefaults() {
        settingsStorageService.reset()
        settings = AppSettings()
        prewarmCurrentModel()
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
            isHotkeyRunning = hotkeyService.isRunning
            hotkeyStatusMessage = hotkeyService.isRunning
                ? "Running"
                : "Could not start the global hotkey listener."
        } catch {
            isHotkeyRunning = false
            hotkeyStatusMessage = error.localizedDescription
            lastErrorMessage = error.localizedDescription
            status = .error
        }
    }

    private func showError(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        status = .error
    }

    private func showPasteFallback(_ error: Error) {
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
            audioLevel: audioLevel,
            microphoneSensitivity: settings.microphoneSensitivity
        )
    }

    private func playFeedbackSound(_ feedback: FeedbackSound) {
        guard let sound = NSSound(named: feedback.soundName) else {
            NSSound.beep()
            return
        }

        sound.volume = feedback.volume
        sound.play()
    }
}

private enum FeedbackSound {
    case recordingStarted
    case recordingStopped
    case pasted

    var soundName: NSSound.Name {
        switch self {
        case .recordingStarted:
            .init("Tink")
        case .recordingStopped:
            .init("Pop")
        case .pasted:
            .init("Ping")
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

private final class DictationTiming {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.ochurkin.FlowType", category: "DictationTiming")
    private let start = ContinuousClock.now
    private var last = ContinuousClock.now

    func mark(_ message: String) {
        let now = ContinuousClock.now
        let total = start.duration(to: now).timeInterval
        let delta = last.duration(to: now).timeInterval
        last = now

        let line = "[FlowTypeTiming] +\(Self.format(delta))s total=\(Self.format(total))s \(message)"
        Self.logger.debug("\(line, privacy: .public)")
    }

    func finish(_ message: String) {
        mark("finished \(message)")
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }
    #else
    func mark(_ message: String) {}
    func finish(_ message: String) {}
    #endif
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

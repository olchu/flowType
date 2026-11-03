import AppKit
import AVFoundation
import Combine
import Foundation
import os

@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .ready {
        didSet {
            // Dictating while placing the indicator keeps where it was left,
            // so the real voice drives it, not the made-up one.
            if status == .recording {
                finishIndicatorPositioning(keeps: true)
            } else {
                handsFreeLimit?.cancel()
            }
            updateFloatingIndicator()
            updateEscapeInterception()
        }
    }
    @Published var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            settingsStorageService.save(settings)
            hotkeyService.dictationKey = settings.dictationKey
            floatingIndicatorController.placement = settings.indicatorPosition
            if settings.indicatorAppearance != oldValue.indicatorAppearance {
                updateFloatingIndicator()
            }
            if settings.profile != oldValue.profile {
                prewarmCurrentModel()
            }
            if settings.cleanupMode == .localLLM
                && (oldValue.cleanupMode != .localLLM || oldValue.cleanupModel != settings.cleanupModel) {
                prewarmTranscriptCleanupModel()
            }
            if settings.externalLLM.provider != oldValue.externalLLM.provider {
                loadExternalLLMAPIKey()
            }
            // The models and the last check belong to the old server.
            if settings.externalLLM.baseURL != oldValue.externalLLM.baseURL {
                externalLLMModels = []
                externalLLMMessage = nil
            }
        }
    }
    /// The external cleanup model's key for the chosen provider, kept in
    /// the Keychain.
    @Published var externalLLMAPIKey = "" {
        didSet {
            let key = externalLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key != storedExternalLLMAPIKey else { return }
            storedExternalLLMAPIKey = key
            Keychain.set(key.isEmpty ? nil : Data(key.utf8), for: Self.externalLLMKeyAccount(settings.externalLLM.provider))
        }
    }
    /// What the Keychain holds for the chosen provider, so loading a key
    /// doesn't write it back.
    private var storedExternalLLMAPIKey = ""
    /// The models the external server offers, once it has been checked.
    @Published private(set) var externalLLMModels: [String] = []
    @Published private(set) var isCheckingExternalLLM = false
    /// The outcome of the last check, and whether it went well.
    @Published private(set) var externalLLMMessage: (text: String, isSuccess: Bool)?
    /// Kept in the Keychain rather than the settings: they hold addresses
    /// and phone numbers.
    @Published var snippets: [Snippet] = [] {
        didSet {
            guard snippets != oldValue else { return }
            // Once typing pauses, not on every key.
            snippetsSave?.cancel()
            snippetsSave = Task { [snippets] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                Keychain.set(try? JSONEncoder().encode(snippets), for: Self.snippetsAccount)
            }
        }
    }
    let history = DictationHistory()
    @Published var lastErrorMessage: String?
    /// The microphones connected right now.
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var isHotkeyRunning = false
    /// While the user drags the indicator to where it should appear.
    @Published private(set) var isPositioningIndicator = false
    /// False when another app already holds ⌃⌥V.
    @Published private(set) var isPasteLastHotKeyAvailable = false
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
    private var hasCompletedOnboarding = false
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusMessage = "Disabled"
    @Published private(set) var isCleanupModelWarmingUp = false
    @Published private(set) var cleanupModelMessage = "Local LLM cleanup is not loaded."

    private let audioRecorder = AudioRecorderService()
    private let hotkeyService = HotkeyService()
    private var keyGesture = DictationKeyGesture()
    private var secondPressTimeout: Task<Void, Never>?
    /// Runs for the length of a hands-free recording.
    private var handsFreeLimit: Task<Void, Never>?
    private let permissionsService = PermissionsService()
    private let transcriptionService = TranscriptionService()
    private let transcriptCleanupService = TranscriptCleanupService()
    private let speechDetector = SpeechDetectionService()
    private let textInserter = TextInserter()
    private let modelStorageService = ModelStorageService()
    private let settingsStorageService = SettingsStorageService()
    private let loginItemService = LoginItemService()
    private let floatingIndicatorController = FloatingIndicatorController()
    private let feedbackSoundPlayer = FeedbackSoundPlayer()
    private let finalTailSilenceMargin: TimeInterval = 0.5
    private lazy var onboardingWindowController = OnboardingWindowController(appState: self)
    private var dictationTargetApplication: NSRunningApplication?
    /// The last transcript, kept in memory only, so ⌃⌥V can paste it again
    /// when the original paste went nowhere.
    private var lastTranscript: String?
    /// While an earlier dictation is pasted again, by ⌃⌥V or from the
    /// history, so a second request doesn't start another paste on top.
    private var isPasting = false
    private var snippetsSave: Task<Void, Never>?
    /// The app in front before Flow Type's own windows, where a paste from
    /// the history goes.
    private var lastActiveApplication = NSWorkspace.shared.frontmostApplication
    private var applicationActivation: AnyCancellable?
    private var streamingTranscriptionTask: Task<Void, Never>?
    /// Processing of the last dictation, or the stream shutdown of a cancelled
    /// one. The next dictation's stream waits for it: the stream and the final
    /// decode share one WhisperKit pipeline.
    private var dictationTask: Task<Void, Never>?
    /// Set once the text is on its way into the app; from then on Escape
    /// can't cancel the dictation.
    private var isDeliveringTranscript = false {
        didSet {
            updateEscapeInterception()
        }
    }
    /// The start cue plays through the speakers and reaches the microphone;
    /// until its loud part ends the indicator would show it as speech.
    private static let startCueMaskDuration: Duration = .milliseconds(450)
    private var startCueMaskEnd: ContinuousClock.Instant?
    /// Smoothed microphone level; goes straight to the indicator, bypassing
    /// the status update path because it changes at buffer rate.
    private var audioLevel: Double = 0 {
        didSet {
            floatingIndicatorController.setAudioLevel(
                Self.gatedLevel(audioLevel, sensitivity: settings.microphoneSensitivity),
                bands: spectrum
            )
        }
    }
    /// The shape of the latest buffer's spectrum, for the Particles peaks.
    private var spectrum = SpectrumBands.zero

    init() {
        settings = settingsStorageService.load()
        snippets = Keychain.data(for: Self.snippetsAccount).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        loadExternalLLMAPIKey()
        applicationActivation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sink { [weak self] in self?.lastActiveApplication = $0 }
        floatingIndicatorController.placement = settings.indicatorPosition
        hasCompletedOnboarding = settingsStorageService.hasCompletedOnboarding()
        audioRecorder.onLevelChanged = { [weak self] level, bands in
            guard let self else { return }
            updateAudioLevel(level, bands: bands)
        }
        microphones = AudioInputDevices.all()
        AudioInputDevices.onChange { [weak self] in
            let microphones = AudioInputDevices.all()
            if microphones != self?.microphones {
                self?.microphones = microphones
            }
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.showOnboardingIfNeeded()
        }
    }

    deinit {
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
        // Not while ⌃⌥V is pasting: its ⌘V would land in the dictation.
        guard canStartRecording, !isPasting else { return }

        lastErrorMessage = nil
        audioLevel = 0

        let timing = DictationTiming()
        timing.mark("start requested")

        // Not connected right now: the system's microphone takes over.
        let microphone = microphones.first { $0.uid == settings.microphoneUID }?.id

        do {
            try audioRecorder.startRecording(inputDeviceID: microphone)
            timing.mark("audio recording started")
        } catch {
            showError(error)
            return
        }

        dictationTargetApplication = NSWorkspace.shared.frontmostApplication
        // An earlier delivery may still be finishing if something else moved
        // the status on meanwhile.
        isDeliveringTranscript = false
        status = .recording
        playFeedback(.recordingStarted)
        startCueMaskEnd = settings.playsSounds ? .now + Self.startCueMaskDuration : nil

        streamingTranscriptionTask?.cancel()
        let previousDictation = dictationTask
        streamingTranscriptionTask = Task { [weak self] in
            await previousDictation?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await transcriptionService.startStreamingTranscription(
                    language: settings.language,
                    model: settings.profile.model,
                    inputDeviceID: microphone
                )
            } catch {
                guard !Task.isCancelled else { return }
                _ = audioRecorder.stopRecording()
                showError(error)
            }
        }
    }

    /// Escape during a dictation drops the recording, or its processing if
    /// the key was already released, and nothing is pasted.
    func cancelDictation() {
        switch status {
        case .recording:
            _ = audioRecorder.stopRecording()
            let streamingTask = streamingTranscriptionTask
            streamingTask?.cancel()
            streamingTranscriptionTask = nil
            dictationTask = Task { [weak self] in
                await streamingTask?.value
                _ = await self?.transcriptionService.stopStreamingTranscription()
            }
            playFeedback(.recordingStopped)
        case .transcribing:
            // Too late: the text is already on its way into the app.
            guard !isDeliveringTranscript else { return }
            // WhisperKit stops at its next cancellation check; the task
            // itself returns before the cleanup and before pasting.
            dictationTask?.cancel()
        case .ready, .error:
            return
        }

        audioLevel = 0
        status = .ready
    }

    func finishDictation() {
        guard canStopRecording else { return }

        audioLevel = 0
        status = .transcribing
        playFeedback(.recordingStopped)

        // Taken now: after the awaits below the slot may already hold the
        // next dictation's stream.
        let streamingTask = streamingTranscriptionTask
        streamingTranscriptionTask = nil

        dictationTask = Task {
            let timing = DictationTiming()
            timing.mark("finish requested")
            // Checked between stages: a cancelled decode returns its fallback
            // text instead of throwing, and the cleanup doesn't check at all.
            func isCancelled() -> Bool {
                guard Task.isCancelled else { return false }
                timing.finish("cancelled")
                return true
            }

            let recordedAudio = audioRecorder.stopRecording()
            timing.mark("audio stopped duration=\(formattedSeconds(recordedAudio.duration))s samples=\(recordedAudio.samples.count)")

            // Independent of the stream, so it runs while the stream stops.
            async let speechDetection = speechDetector.detect(in: recordedAudio)
            let streamingResult = await transcriptionService.stopStreamingTranscription()
            timing.mark(
                "stream stopped textChars=\(streamingResult.transcript.count) confirmedChars=\(streamingResult.confirmedTranscript.count) confirmedEnd=\(formattedSeconds(streamingResult.confirmedEndSeconds))s streamAudio=\(formattedSeconds(streamingResult.audio.duration))s"
            )

            streamingTask?.cancel()

            let rawTranscript = await finalTranscript(
                from: recordedAudio,
                speechDetection: await speechDetection,
                streamingResult: streamingResult,
                timing: timing
            )
            timing.mark("final transcript ready chars=\(rawTranscript.count)")
            if isCancelled() { return }

            // A dictation of nothing but a command: a snippet, pasted as
            // written, or «отмени». Before the cleanup, which could reword it.
            let spoken = TranscriptText.clean(rawTranscript)
            if let snippet = snippets.first(where: { $0.triggers.contains { PhraseReplacements.isWhole(spoken, phrase: $0) } }) {
                await deliver(snippet.text, fitting: .spacesOnly, timing: timing)
                return
            }
            if settings.undoesByVoice && Self.undoCommands.contains(where: { PhraseReplacements.isWhole(spoken, phrase: $0) }) {
                if textInserter.undo() {
                    playFeedback(.pasted)
                } else {
                    beep()
                }
                status = .ready
                timing.finish("undo")
                return
            }

            let cleanupResult = await transcriptCleanupService.clean(
                rawTranscript,
                mode: settings.cleanupMode,
                model: settings.cleanupModel,
                external: externalLLMConfiguration,
                rules: settings.textRules(snippets: snippets)
            )
            let transcript = cleanupResult.text
            timing.mark(
                "cleanup completed mode=\(settings.cleanupMode.rawValue) model=\(cleanupModelName) decision=\(cleanupResult.decision) rawChars=\(rawTranscript.count) chars=\(transcript.count)"
            )

            if isCancelled() { return }
            await deliver(transcript, fitting: settings.fitsTextAroundCursor ? .full : .none, timing: timing)
        }
    }

    /// Pastes or copies a dictation's text, and keeps it for ⌃⌥V and the
    /// history.
    private func deliver(_ transcript: String, fitting: TextInserter.Fitting, timing: DictationTiming) async {
        isDeliveringTranscript = true
        // Cleared on the way out, after the status has left .transcribing,
        // so Escape isn't intercepted again in between.
        defer { isDeliveringTranscript = false }

        guard !transcript.isEmpty else {
            status = .ready
            timing.finish("empty transcript")
            return
        }

        lastTranscript = transcript
        var pasteError: Error?
        if settings.autoPaste {
            do {
                try await textInserter.paste(
                    transcript,
                    into: dictationTargetApplication,
                    restoreClipboard: settings.restoreClipboard,
                    fitting: fitting,
                    keptSpellings: keptSpellings
                )
                timing.mark("paste completed")
            } catch {
                pasteError = error
            }
        } else {
            textInserter.copy(transcript)
            timing.mark("copied to clipboard")
        }
        // After the paste, so writing it doesn't hold the text up.
        if settings.keepsHistory {
            history.add(transcript, appName: dictationTargetApplication?.localizedName)
        }

        if let pasteError {
            showError(pasteError)
            timing.finish("paste failed")
            return
        }
        if settings.autoPaste {
            playFeedback(.pasted)
        }
        // Before .ready, so the confirmation is already up and the ready
        // status doesn't start a dismissal.
        floatingIndicatorController.showPasted()
        status = .ready
        timing.finish("ready")
    }

    private func finalTranscript(
        from recordedAudio: RecordedAudio,
        speechDetection: SpeechDetectionService.Detection,
        streamingResult: TranscriptionService.StreamingTranscriptionResult,
        timing: DictationTiming
    ) async -> String {
        let streamingTranscript = streamingResult.transcript

        // Silero decides whether there was any speech; the energy check stands
        // in while the VAD model is still loading. Only the trailing silence is
        // cut, and only for Whisper, which invents text for it. The start is
        // never cut: Silero works in 256 ms steps, so its speech start can
        // clip a first syllable, and dropping it would not speed anything up.
        let speechAudio: RecordedAudio
        switch speechDetection {
        case .noSpeech:
            timing.mark("speech gate skipped final decode vad=silero")
            return ""
        case .unavailable:
            guard recordedAudio.containsLikelySpeech else {
                timing.mark("speech gate skipped final decode vad=energy")
                return ""
            }
            speechAudio = recordedAudio
        case .speech(let start, let end):
            speechAudio = settings.profile.model.trimsTrailingSilence
                ? recordedAudio.prefix(seconds: end)
                : recordedAudio
            timing.mark(
                "vad speech=\(formattedSeconds(start))-\(formattedSeconds(end))s of \(formattedSeconds(recordedAudio.duration))s"
            )
        }

        do {
            timing.mark("finalization mode=\(settings.finalizationMode.rawValue)")

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
                timing.mark("final decode skipped reason=stream-only")
                return streamingTranscript

            case .streamTail:
                return try await streamTailTranscript(
                    speechAudio: speechAudio,
                    streamingResult: streamingResult,
                    timing: timing
                )
            }
        } catch {
            timing.mark("final decode failed fallback=stream error=\(error.localizedDescription)")
            return streamingTranscript
        }
    }

    private func fullTranscript(of audio: RecordedAudio, reason: String, timing: DictationTiming) async throws -> String {
        timing.mark("full decode started reason=\(reason) window=\(formattedSeconds(audio.duration))s")
        let transcript = try await transcriptionService.transcribe(
            audio,
            language: settings.language,
            model: settings.profile.model
        )
        timing.mark("full decode completed chars=\(transcript.count)")
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
        timing: DictationTiming
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
            timing.mark("tail decode skipped reason=no-speech vad=silero tail=\(formattedSeconds(tailAudio.duration))s")
            return confirmedTranscript
        case .speech(_, let end):
            speechEnd = end
        case .unavailable:
            guard let energySpeechEnd = tailAudio.lastSpeechEnd(noiseFloor: streamingResult.audio.noiseFloor) else {
                timing.mark("tail decode skipped reason=no-speech vad=energy tail=\(formattedSeconds(tailAudio.duration))s")
                return confirmedTranscript
            }
            // The margin keeps quiet word endings the energy check misses.
            speechEnd = energySpeechEnd + finalTailSilenceMargin
        }

        let trimmedTail = tailAudio.prefix(seconds: speechEnd)
        timing.mark(
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
        timing.mark("tail decode completed chars=\(tailTranscript.count)")

        return TranscriptText.joined(prefix: confirmedTranscript, continuation: tailTranscript)
    }

    private func updateAudioLevel(_ level: Double, bands: SpectrumBands) {
        if let startCueMaskEnd, ContinuousClock.now < startCueMaskEnd {
            return
        }

        spectrum = bands
        let clampedLevel = min(1, max(0, level))
        let smoothing = clampedLevel > audioLevel ? 0.6 : 0.3
        audioLevel += (clampedLevel - audioLevel) * smoothing
    }

    /// Shows the indicator so the user can drag it where it should appear.
    func beginIndicatorPositioning() {
        guard status != .recording, status != .transcribing else { return }
        isPositioningIndicator = floatingIndicatorController.beginPositioning(appearance: settings.indicatorAppearance)
    }

    /// Hides the indicator again, keeping where it was left if `keeps`.
    func finishIndicatorPositioning(keeps: Bool) {
        guard isPositioningIndicator else { return }
        isPositioningIndicator = false
        if let centre = floatingIndicatorController.endPositioning(keeps: keeps) {
            settings.indicatorPosition = centre
        }
        // Back to what the indicator should show: nothing, or the model
        // still loading.
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

    /// The model that cleans up dictations, for the timing log.
    private var cleanupModelName: String {
        switch settings.cleanupMode {
        case .localLLM: settings.cleanupModel.rawValue
        case .externalLLM: "\(settings.externalLLM.provider.rawValue)/\(settings.externalLLM.model)"
        case .localRules, .off: "none"
        }
    }

    private func loadExternalLLMAPIKey() {
        storedExternalLLMAPIKey = Self.externalLLMAPIKey(for: settings.externalLLM.provider)
        externalLLMAPIKey = storedExternalLLMAPIKey
    }

    /// What a dictation sends to the external cleanup model. Snippets stay
    /// out of it: they hold addresses and phone numbers.
    var externalLLMConfiguration: ExternalLLMConfiguration {
        Self.externalLLMConfiguration(settings, apiKey: externalLLMAPIKey)
    }

    nonisolated static func externalLLMConfiguration(_ settings: AppSettings, apiKey: String) -> ExternalLLMConfiguration {
        ExternalLLMConfiguration(
            settings: settings.externalLLM,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            vocabulary: settings.wordReplacements.map(\.written)
        )
    }

    /// Loads the server's models and cleans up a test phrase, to show the
    /// connection works and how fast it answers.
    func checkExternalLLM() {
        guard !isCheckingExternalLLM else { return }
        let configuration = externalLLMConfiguration
        isCheckingExternalLLM = true
        externalLLMMessage = nil

        Task {
            defer { isCheckingExternalLLM = false }
            // Not every server lists its models; the test phrase decides.
            async let listedModels = (try? await ExternalLLMClient.models(configuration: configuration)) ?? []
            async let test = Self.testResult(configuration)
            let (models, result) = await (listedModels, test)
            // Changed meanwhile: the outcome is the old settings'.
            guard configuration == externalLLMConfiguration else { return }

            externalLLMModels = models
            switch result {
            case let .success(result):
                let seconds = result.duration / .seconds(1)
                externalLLMMessage = ("Answered in \(seconds.formatted(.number.precision(.fractionLength(1)))) s: \u{201C}\(result.text)\u{201D}", true)
            case let .failure(error):
                externalLLMMessage = (error.localizedDescription, false)
            }
        }
    }

    private nonisolated static func testResult(
        _ configuration: ExternalLLMConfiguration
    ) async -> Result<(text: String, duration: Duration), Error> {
        do {
            return .success(try await TranscriptCleanupService.testExternalLLM(configuration))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func externalLLMAPIKey(for provider: ExternalLLMProvider) -> String {
        Keychain.data(for: externalLLMKeyAccount(provider)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private nonisolated static func externalLLMKeyAccount(_ provider: ExternalLLMProvider) -> String {
        "external-llm-key.\(provider.rawValue)"
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
        // Once denied, macOS no longer asks; only System Settings can change it.
        guard microphonePermission == .notDetermined else {
            permissionsService.openMicrophoneSettings()
            return
        }

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

    /// Lets the volume be judged by ear from Settings.
    func previewFeedbackSound(_ sound: FeedbackSound = .recordingStarted) {
        playFeedback(sound)
    }

    private func playFeedback(_ sound: FeedbackSound) {
        guard settings.playsSounds else { return }
        feedbackSoundPlayer.play(sound, volume: settings.soundVolume)
    }

    func resetSettingsToDefaults() {
        var defaults = AppSettings()
        // The dictionary is the user's own words, not a setting.
        defaults.wordReplacements = settings.wordReplacements
        settings = defaults
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

        hotkeyService.dictationKey = settings.dictationKey

        hotkeyService.onKeyDown = { [weak self] time in
            guard let self else { return }
            perform(keyGesture.press(at: time, isRecording: status == .recording))
        }

        hotkeyService.onKeyUp = { [weak self] time in
            guard let self else { return }
            perform(keyGesture.release(at: time, allowsHandsFree: settings.handsFreeByDoublePress))
        }

        hotkeyService.onEscape = { [weak self] in
            self?.cancelDictation()
        }

        hotkeyService.onPasteLast = { [weak self] in
            self?.pasteLastTranscript()
        }

        hotkeyService.onUserInput = { [weak self] in
            guard let self else { return }
            textInserter.forgetLastInsertion()
            // Fn is no modifier in shortcuts. Only a recording counts, not an
            // earlier dictation still being processed.
            if settings.dictationKey != .fn && status == .recording {
                perform(keyGesture.interrupted())
            }
        }

        do {
            try hotkeyService.start()
            isHotkeyRunning = true
            isPasteLastHotKeyAvailable = hotkeyService.isPasteLastHotKeyRegistered
            hotkeyStatusMessage = "Running"
        } catch {
            isHotkeyRunning = false
            hotkeyStatusMessage = error.localizedDescription
            showError(error)
        }
    }

    private func perform(_ step: DictationKeyGesture.Step) {
        // Keeps the timeout running: `.none` also answers keys typed while
        // it waits, and once it isn't waiting the timeout does nothing.
        guard step != .none else { return }

        secondPressTimeout?.cancel()
        switch step {
        case .none:
            break
        case .start:
            startDictation()
        case .finish:
            finishDictation()
        case .cancel:
            cancelDictation()
        case .startHandsFree:
            let limit = Duration.seconds(settings.handsFreeLimitMinutes * 60)
            handsFreeLimit = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.finishDictation()
            }
        case .awaitSecondPress:
            secondPressTimeout = Task { [weak self] in
                try? await Task.sleep(for: DictationKeyGesture.secondPressWindow)
                guard !Task.isCancelled, let self else { return }
                perform(keyGesture.secondPressTimedOut())
            }
        }
    }

    private func pasteLastTranscript() {
        guard status != .recording, status != .transcribing else { return }
        guard let transcript = lastTranscript else {
            beep()
            return
        }
        pasteAgain(transcript, into: NSWorkspace.shared.frontmostApplication)
    }

    /// Into the app that was in front before the history window.
    func pasteFromHistory(_ entry: HistoryEntry) {
        pasteAgain(entry.text, into: lastActiveApplication)
    }

    func copy(_ text: String) {
        textInserter.copy(text)
    }

    /// Pastes an earlier dictation. It pastes even with automatic paste off:
    /// asking for it asks for exactly that.
    private func pasteAgain(_ text: String, into application: NSRunningApplication?) {
        guard status != .recording, status != .transcribing, !isPasting else { return }
        guard let application else {
            beep()
            return
        }

        isPasting = true
        Task {
            defer { isPasting = false }
            do {
                try await textInserter.paste(
                    text,
                    into: application,
                    restoreClipboard: settings.restoreClipboard,
                    fitting: settings.fitsTextAroundCursor ? .full : .none,
                    keptSpellings: keptSpellings
                )
            } catch {
                showError(error)
                return
            }
            playFeedback(.pasted)
            // A paste that failed has been made good.
            if status == .error {
                clearError()
            }
        }
    }

    private var keptSpellings: [String] {
        settings.wordReplacements.map(\.written) + snippets.map(\.text)
    }

    private static let snippetsAccount = "snippets"

    private static let undoCommands = [
        "отмени", "отмени это", "отмени последнее", "удали последнее", "удали это",
        "undo", "undo that", "delete that", "scratch that",
    ]

    private func beep() {
        if settings.playsSounds {
            NSSound.beep()
        }
    }

    private func showError(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        status = .error
    }

    private func updateEscapeInterception() {
        hotkeyService.interceptsEscape = (status == .recording || status == .transcribing)
            && !isDeliveringTranscript
    }

    private func updateFloatingIndicator() {
        floatingIndicatorController.update(
            for: status,
            isModelLoading: isModelWarmingUp,
            appearance: settings.indicatorAppearance
        )
    }

    /// Higher sensitivity lowers the level below which the bars stay idle.
    private static func gatedLevel(_ level: Double, sensitivity: Double) -> Double {
        let threshold = 0.09 - min(max(sensitivity, 0), 1) * 0.08
        return max(0, (level - threshold) / max(0.01, 1 - threshold))
    }
}

enum FeedbackSound: CaseIterable {
    case recordingStarted
    case recordingStopped
    case pasted

    var title: String {
        switch self {
        case .recordingStarted:
            "Recording starts"
        case .recordingStopped:
            "Recording stops"
        case .pasted:
            "Text pasted"
        }
    }

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

    /// Player volume at the top of the volume slider; the default slider
    /// position plays at half of it.
    var maximumVolume: Float {
        switch self {
        case .recordingStarted, .recordingStopped:
            0.36
        case .pasted:
            0.5
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
        for sound in FeedbackSound.allCases {
            guard let url = Bundle.main.url(forResource: sound.fileName, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[sound] = player
        }
    }

    /// - Parameter volume: The user's volume setting, 0...1.
    func play(_ sound: FeedbackSound, volume: Double) {
        for (other, player) in players where other != sound && player.isPlaying {
            player.setVolume(0, fadeDuration: Self.handoffFade)
        }

        guard let player = players[sound] else {
            NSSound.beep()
            return
        }
        player.stop()
        player.currentTime = 0
        player.volume = sound.maximumVolume * Float(min(max(volume, 0), 1))
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

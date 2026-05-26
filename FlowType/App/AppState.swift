import AppKit
import Combine
import Foundation

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
        }
    }
    @Published var lastTranscript = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var isHotkeyRunning = false
    @Published private(set) var hotkeyStatusMessage = "Waiting for Accessibility permission."
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var microphonePermission: PermissionStatus = .unknown
    @Published private(set) var isModelWarmingUp = false
    @Published private(set) var modelWarmupMessage = "Model is not loaded yet."
    @Published private(set) var modelLoadingProgress: Double = 0
    @Published private(set) var modelStorageStates: [TranscriptionModel: ModelStorageState] = [:]
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var resourceUsage = ProcessResourceUsage()
    @Published private(set) var hasCompletedOnboarding = false
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusMessage = "Disabled"

    private let audioRecorder = AudioRecorderService()
    private let hotkeyService = HotkeyService()
    private let permissionsService = PermissionsService()
    private let transcriptionService = TranscriptionService()
    private let pasteService = PasteService()
    private let modelStorageService = ModelStorageService()
    private let settingsStorageService = SettingsStorageService()
    private let resourceMonitorService = ProcessResourceMonitorService()
    private let loginItemService = LoginItemService()
    private let floatingIndicatorController = FloatingIndicatorController()
    private lazy var onboardingWindowController = OnboardingWindowController(appState: self)
    private var dictationTargetApplication: NSRunningApplication?
    private var resourceUsageTask: Task<Void, Never>?

    init() {
        settings = settingsStorageService.load()
        hasCompletedOnboarding = settingsStorageService.hasCompletedOnboarding()
        audioRecorder.onLevelChanged = { [weak self] level in
            guard let self else { return }
            audioLevel = level
            updateFloatingIndicator()
        }

        refreshPermissions()
        refreshLaunchAtLoginStatus()
        refreshModelStorageStates()
        configureHotkey()
        prewarmCurrentModel()
        startResourceUsageMonitoring()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.showOnboardingIfNeeded()
        }
    }

    deinit {
        resourceUsageTask?.cancel()
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
        audioLevel = 0
        dictationTargetApplication = NSWorkspace.shared.frontmostApplication
        do {
            try audioRecorder.startRecording()
            status = .recording
        } catch {
            showError(error)
        }
    }

    func finishDictation() {
        guard canStopRecording else { return }

        audioLevel = 0
        let audio = audioRecorder.stopRecording()

        guard audio.containsLikelySpeech else {
            lastTranscript = ""
            status = .ready
            return
        }

        status = .transcribing

        Task {
            do {
                let transcript = try await transcriptionService.transcribe(
                    audio,
                    language: settings.language,
                    model: settings.profile.model
                )
                lastTranscript = transcript

                if settings.autoPaste {
                    do {
                        try await pasteService.pasteText(
                            transcript,
                            restoreClipboard: settings.restoreClipboard,
                            into: dictationTargetApplication
                        )
                    } catch {
                        showPasteFallback(error)
                        return
                    }
                }

                status = .ready
            } catch {
                showError(error)
            }
        }
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
            audioLevel: audioLevel,
            microphoneSensitivity: settings.microphoneSensitivity
        )
    }
}

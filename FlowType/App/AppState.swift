import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .ready
    @Published var settings = AppSettings()
    @Published var lastTranscript = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var isHotkeyRunning = false
    @Published private(set) var hotkeyStatusMessage = "Waiting for Accessibility permission."
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var microphonePermission: PermissionStatus = .unknown
    @Published private(set) var isModelWarmingUp = false
    @Published private(set) var modelWarmupMessage = "Model is not loaded yet."

    private let audioRecorder = AudioRecorderService()
    private let hotkeyService = HotkeyService()
    private let permissionsService = PermissionsService()
    private let transcriptionService = TranscriptionService()
    private let pasteService = PasteService()
    private var dictationTargetApplication: NSRunningApplication?

    init() {
        refreshPermissions()
        configureHotkey()
        prewarmCurrentModel()
    }

    var canStartRecording: Bool {
        (status == .ready || status == .error)
            && microphonePermission.isGranted
            && !isModelWarmingUp
    }

    var canStopRecording: Bool {
        status == .recording
    }

    func startDictation() {
        guard canStartRecording else { return }

        lastErrorMessage = nil
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

        status = .transcribing
        let audio = audioRecorder.stopRecording()

        Task {
            do {
                let transcript = try await transcriptionService.transcribe(
                    audio,
                    language: settings.language,
                    model: settings.model
                )
                lastTranscript = transcript

                if settings.autoPaste {
                    try await pasteService.pasteText(
                        transcript,
                        restoreClipboard: settings.restoreClipboard,
                        into: dictationTargetApplication
                    )
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

        let model = settings.model
        isModelWarmingUp = true
        modelWarmupMessage = "Loading \(model.rawValue)..."

        Task {
            do {
                try await transcriptionService.prewarm(model: model)
                modelWarmupMessage = "\(model.rawValue) is ready."
            } catch {
                modelWarmupMessage = "Could not load \(model.rawValue)."
                showError(error)
            }

            isModelWarmingUp = false
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
}

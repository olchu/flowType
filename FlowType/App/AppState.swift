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

    private let audioRecorder = AudioRecorderService()
    private let hotkeyService = HotkeyService()
    private let permissionsService = PermissionsService()
    private let transcriptionService = TranscriptionService()
    private let pasteService = PasteService()

    init() {
        refreshPermissions()
        configureHotkey()
    }

    var canStartRecording: Bool {
        (status == .ready || status == .error) && microphonePermission.isGranted
    }

    var canStopRecording: Bool {
        status == .recording
    }

    func startDictation() {
        guard canStartRecording else { return }

        lastErrorMessage = nil
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
                    try pasteService.pasteText(
                        transcript,
                        restoreClipboard: settings.restoreClipboard
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

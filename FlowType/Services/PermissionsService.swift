import AVFoundation
import ApplicationServices
import AppKit
import Foundation

@MainActor
final class PermissionsService {
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func promptForAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        probeAccessibilityProtectedAPI()
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]

        for string in urls {
            guard let url = URL(string: string), NSWorkspace.shared.open(url) else { continue }
            break
        }
    }

    private func probeAccessibilityProtectedAPI() {
        let events = 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, _, event, _ in
            Unmanaged.passUnretained(event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(events),
            callback: callback,
            userInfo: nil
        ) else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: false)
    }
}

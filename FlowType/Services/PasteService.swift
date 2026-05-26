import AppKit
import Foundation

@MainActor
final class PasteService {
    enum PasteError: LocalizedError {
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .eventCreationFailed:
                "Could not create paste keyboard events."
            }
        }
    }

    private let pasteboard = NSPasteboard.general

    func pasteText(
        _ text: String,
        restoreClipboard: Bool,
        into targetApplication: NSRunningApplication?
    ) async throws {
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        await activate(targetApplication)
        try sendPasteCommand()

        if restoreClipboard {
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private func activate(_ application: NSRunningApplication?) async {
        guard
            let application,
            !application.isTerminated,
            application.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return
        }

        application.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func sendPasteCommand() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            throw PasteError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

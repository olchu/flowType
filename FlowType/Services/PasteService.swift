import AppKit
import Foundation

@MainActor
final class PasteService {
    enum PasteError: LocalizedError {
        case accessibilityPermissionMissing
        case accessibilityInsertionFailed
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionMissing:
                "Automatic paste needs Accessibility permission. The transcript was copied to the clipboard."
            case .accessibilityInsertionFailed:
                "Could not insert text into the focused field. The transcript was copied to the clipboard."
            case .eventCreationFailed:
                "Could not create paste keyboard events. The transcript was copied to the clipboard."
            }
        }
    }

    private let pasteboard = NSPasteboard.general

    func pasteText(
        _ text: String,
        restoreClipboard: Bool,
        into targetApplication: NSRunningApplication?
    ) async throws {
        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            throw PasteError.accessibilityPermissionMissing
        }

        await activate(targetApplication)

        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        copyToClipboard(text)

        let usesSharedClipboard = isParallelsApplication(targetApplication)
        if usesSharedClipboard {
            // Parallels synchronizes the host pasteboard with the guest
            // asynchronously. Pasting immediately can insert stale guest
            // clipboard contents instead of the new transcript.
            try? await Task.sleep(for: .milliseconds(1_500))
        }

        do {
            if usesSharedClipboard {
                if !pasteUsingApplicationMenu(targetApplication) {
                    try sendParallelsPasteCommand()
                }
            } else {
                try sendPasteCommand()
            }
        } catch {
            guard insertTextUsingAccessibility(text) else {
                throw error
            }
        }

        if restoreClipboard && !usesSharedClipboard {
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

    private func isParallelsApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }

        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        let executableName = application.executableURL?.lastPathComponent.lowercased() ?? ""
        return bundleIdentifier.contains("parallels") || executableName.hasPrefix("prl_")
    }

    private func pasteUsingApplicationMenu(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard
            let menuBar = elementAttribute(kAXMenuBarAttribute, of: applicationElement),
            let editMenuBarItem = childElements(of: menuBar).first(where: {
                stringAttribute(kAXTitleAttribute, of: $0) == "Edit"
            }),
            let editMenu = childElements(of: editMenuBarItem).first,
            let pasteMenuItem = childElements(of: editMenu).first(where: {
                stringAttribute(kAXTitleAttribute, of: $0) == "Paste"
            })
        else {
            return false
        }

        return AXUIElementPerformAction(pasteMenuItem, kAXPressAction as CFString) == .success
    }

    private func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &value
            ) == .success,
            let children = value as? [AXUIElement]
        else {
            return []
        }

        return children
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func insertTextUsingAccessibility(_ text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let focusedElementResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard
            focusedElementResult == .success,
            let focusedElement,
            CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            focusedElement as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        return result == .success
    }

    private func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    private func sendParallelsPasteCommand() throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            throw PasteError.eventCreationFailed
        }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []

        // Parallels forwards physical key transitions to the guest. A V event
        // carrying only maskCommand loses the modifier and types a literal V.
        commandDown.post(tap: .cghidEventTap)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
    }
}

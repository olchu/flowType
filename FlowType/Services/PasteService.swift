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

    /// Clipboard contents a paste replaced, waiting to be put back once the
    /// paste target has read the transcript.
    private struct PendingRestore {
        let snapshot: ClipboardSnapshot
        let owner: TranscriptPasteboardOwner
        let changeCount: Int
        let task: Task<Void, Never>
    }

    /// Restore this long after the target's last read. Apps may read more
    /// than one type per paste, and the reads don't arrive together.
    private static let quietPeriodAfterRead: Duration = .milliseconds(200)
    /// Restore anyway if the target never reads the transcript, for example
    /// when ⌘V went nowhere or a clipboard manager read it before the paste.
    private static let restoreTimeout: Duration = .seconds(5)

    private let pasteboard = NSPasteboard.general
    private var pendingRestore: PendingRestore?

    func copyText(_ text: String) {
        settlePendingRestore()
        copyToClipboard(text)
    }

    func pasteText(
        _ text: String,
        restoreClipboard: Bool,
        into targetApplication: NSRunningApplication?
    ) async throws {
        guard AXIsProcessTrusted() else {
            copyText(text)
            throw PasteError.accessibilityPermissionMissing
        }

        await activate(targetApplication)

        // A previous paste may still hold the clipboard. Its restore has to
        // run first, or the snapshot below would capture that transcript
        // instead of the user's contents.
        settlePendingRestore()

        let usesSharedClipboard = isParallelsApplication(targetApplication)
        guard restoreClipboard && !usesSharedClipboard else {
            try await pasteKeepingTranscript(
                text,
                into: targetApplication,
                usesSharedClipboard: usesSharedClipboard
            )
            return
        }

        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        let owner = TranscriptPasteboardOwner(text: text)
        let changeCount = pasteboard.declareTypes(
            [.string] + TranscriptPasteboardOwner.concealedTypes,
            owner: owner
        )

        let pasteSentAt = ContinuousClock.now
        do {
            try sendPasteCommand()
        } catch {
            guard insertTextUsingAccessibility(text) else {
                // The owner doesn't outlive this call, so the transcript the
                // error message promises has to be real data.
                copyToClipboard(text)
                throw error
            }

            // Inserted without the clipboard; nothing is going to read it.
            restoreIfStillOwned(snapshot, owner: owner, changeCount: changeCount)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await restoreAfterTargetReads(
                owner: owner,
                changeCount: changeCount,
                pasteSentAt: pasteSentAt
            )
        }
        pendingRestore = PendingRestore(
            snapshot: snapshot,
            owner: owner,
            changeCount: changeCount,
            task: task
        )
    }

    private func pasteKeepingTranscript(
        _ text: String,
        into targetApplication: NSRunningApplication?,
        usesSharedClipboard: Bool
    ) async throws {
        copyToClipboard(text)

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
    }

    private func restoreAfterTargetReads(
        owner: TranscriptPasteboardOwner,
        changeCount: Int,
        pasteSentAt: ContinuousClock.Instant
    ) async {
        let deadline = pasteSentAt + Self.restoreTimeout

        while true {
            try? await Task.sleep(for: .milliseconds(25))
            // Cancelled when another paste or copy settled this restore.
            guard !Task.isCancelled else { return }

            let now = ContinuousClock.now
            // Reads before ⌘V come from apps reacting to the clipboard change
            // itself, not from the paste target.
            let targetFinishedReading = owner.lastTextReadAt.map {
                $0 >= pasteSentAt && now - $0 >= Self.quietPeriodAfterRead
            } ?? false
            // pasteboardChangedOwner may arrive late or not at all, so a
            // newer copy is detected by the change count as well.
            if owner.hasLostOwnership
                || pasteboard.changeCount != changeCount
                || now >= deadline
                || targetFinishedReading {
                break
            }
        }

        settlePendingRestore()
    }

    private func settlePendingRestore() {
        guard let pending = pendingRestore else { return }

        pendingRestore = nil
        pending.task.cancel()
        restoreIfStillOwned(pending.snapshot, owner: pending.owner, changeCount: pending.changeCount)
    }

    private func restoreIfStillOwned(
        _ snapshot: ClipboardSnapshot,
        owner: TranscriptPasteboardOwner,
        changeCount: Int
    ) {
        // If the user copied something since the paste, their copy wins.
        guard !owner.hasLostOwnership, pasteboard.changeCount == changeCount else { return }
        snapshot.restore(to: pasteboard)
    }

    private func activate(_ application: NSRunningApplication?) async {
        guard
            let application,
            !application.isTerminated,
            application.bundleIdentifier != Bundle.main.bundleIdentifier,
            // Usually still frontmost: Flow Type never takes focus while
            // dictating, and waiting for an activation that is not needed
            // added 150 ms to every paste.
            !application.isActive
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
        guard let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            of: AXUIElementCreateSystemWide()
        ) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            focusedElement,
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

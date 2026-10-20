import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
final class HotkeyService {
    enum HotkeyError: LocalizedError {
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .eventTapCreationFailed:
                "Could not start the global hotkey listener. Grant Accessibility permission and restart Flow Type."
            }
        }
    }

    private struct EventTap {
        let port: CFMachPort
        let source: CFRunLoopSource

        func setEnabled(_ isEnabled: Bool) {
            CGEvent.tapEnable(tap: port, enable: isEnabled)
        }

        func remove() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
    }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?

    /// While true, Escape is taken away from the frontmost app and reported
    /// through `onEscape`. Meant for the length of a dictation only: taking
    /// keys away needs an active tap, and while it is enabled it holds every
    /// key press in the system until this app's main thread has looked at it.
    var interceptsEscape = false {
        didSet {
            updateEscapeTap()
        }
    }

    private static let escapeKeyCode = Int64(kVK_Escape)

    private var fnTap: EventTap?
    /// Created on the first dictation and enabled only while Escape is
    /// intercepted.
    private var escapeTap: EventTap?
    private var isPressed = false
    /// From a swallowed Escape press until its release, so the auto-repeats
    /// and the release don't reach the app either.
    private var isSwallowingEscape = false

    func start() throws {
        guard fnTap == nil else { return }

        guard let fnTap = makeTap(
            events: 1 << CGEventType.flagsChanged.rawValue,
            options: .listenOnly,
            callback: { _, type, event, userInfo in
                if let service = HotkeyService.service(from: userInfo) {
                    Task { @MainActor in
                        service.handleEvent(type: type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            }
        ) else {
            throw HotkeyError.eventTapCreationFailed
        }
        fnTap.setEnabled(true)
        self.fnTap = fnTap
        updateEscapeTap()
    }

    func stop() {
        fnTap?.remove()
        escapeTap?.remove()

        fnTap = nil
        escapeTap = nil
        isPressed = false
        isSwallowingEscape = false
        onKeyDown = nil
        onKeyUp = nil
        onEscape = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            updateFnState(isFnPressed: event.flags.contains(.maskSecondaryFn))
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches the tap off when the main thread stalls past
            // the tap timeout. It stays off until re-enabled, which would
            // leave Fn dead until the app restarts.
            fnTap?.setEnabled(true)
            // A Fn release that happened while the tap was off was never
            // delivered; without this the recording would never stop.
            let flags = CGEventSource.flagsState(.combinedSessionState)
            updateFnState(isFnPressed: flags.contains(.maskSecondaryFn))
        default:
            break
        }
    }

    private func updateFnState(isFnPressed: Bool) {
        switch (isPressed, isFnPressed) {
        case (false, true):
            isPressed = true
            onKeyDown?()
        case (true, false):
            isPressed = false
            onKeyUp?()
        default:
            break
        }
    }

    private func updateEscapeTap() {
        // A release lost while the tap was off would otherwise keep the tap
        // on, holding every key press, until Escape is pressed again.
        if isSwallowingEscape && !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) {
            isSwallowingEscape = false
        }

        let isNeeded = interceptsEscape || isSwallowingEscape
        // Retried on each dictation: without this tap Escape just isn't
        // intercepted, dictation still works.
        if isNeeded && escapeTap == nil && fnTap != nil {
            escapeTap = makeEscapeTap()
        }

        // A held Escape stays intercepted until its release is swallowed too.
        escapeTap?.setEnabled(isNeeded)
    }

    private func makeEscapeTap() -> EventTap? {
        makeTap(
            events: 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue,
            options: .defaultTap,
            callback: { _, type, event, userInfo in
                guard let service = HotkeyService.service(from: userInfo) else {
                    return Unmanaged.passUnretained(event)
                }
                // The tap is on the main run loop, and whether the key is
                // dropped has to be decided before the callback returns.
                let swallows = MainActor.assumeIsolated {
                    service.handleEscapeTapEvent(type: type, event: event)
                }
                return swallows ? nil : Unmanaged.passUnretained(event)
            }
        )
    }

    /// Returns whether the event is swallowed.
    private func handleEscapeTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            updateEscapeTap()
            return false

        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode else {
                return false
            }

            // A fresh press while still swallowing means the release was lost
            // while the tap was off; treat it as a new press.
            let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isSwallowingEscape && isAutorepeat {
                return true
            }

            guard interceptsEscape else {
                isSwallowingEscape = false
                updateEscapeTap()
                return false
            }

            isSwallowingEscape = true
            // Run after the callback returns: cancelling stops the recorder,
            // and the active tap holds every key press until it's done.
            Task {
                self.onEscape?()
            }
            return true

        case .keyUp:
            guard
                event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode,
                isSwallowingEscape
            else {
                return false
            }

            isSwallowingEscape = false
            updateEscapeTap()
            return true

        default:
            return false
        }
    }

    nonisolated private static func service(from userInfo: UnsafeMutableRawPointer?) -> HotkeyService? {
        userInfo.map { Unmanaged<HotkeyService>.fromOpaque($0).takeUnretainedValue() }
    }

    /// The tap is created disabled; callers enable it when it should run.
    private func makeTap(
        events: CGEventMask,
        options: CGEventTapOptions,
        callback: CGEventTapCallBack
    ) -> EventTap? {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: events,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return EventTap(port: port, source: source)
    }
}

import ApplicationServices
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

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?

    /// While true, Escape is taken away from the frontmost app and reported
    /// through `onEscape`. Meant for the length of a dictation only: taking
    /// keys away needs an active tap, and an active tap holds every key press
    /// in the system until this app's main thread has looked at it.
    var interceptsEscape = false {
        didSet {
            updateEscapeTap()
        }
    }

    private static let escapeKeyCode: Int64 = 53

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var escapeTap: CFMachPort?
    private var escapeRunLoopSource: CFRunLoopSource?
    private var isPressed = false
    /// From a swallowed Escape press until its release, so the auto-repeats
    /// and the release don't reach the app either.
    private var isSwallowingEscape = false

    func start() throws {
        guard eventTap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in
                service.handleEvent(type: type, event: event)
            }

            return Unmanaged.passUnretained(event)
        }

        guard let (eventTap, runLoopSource) = makeTap(
            events: 1 << CGEventType.flagsChanged.rawValue,
            options: .listenOnly,
            callback: callback
        ) else {
            throw HotkeyError.eventTapCreationFailed
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
    }

    func stop() {
        removeTap(eventTap, runLoopSource)
        removeTap(escapeTap, escapeRunLoopSource)

        runLoopSource = nil
        eventTap = nil
        escapeRunLoopSource = nil
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
            guard let eventTap else { return }
            CGEvent.tapEnable(tap: eventTap, enable: true)
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
        if interceptsEscape {
            startEscapeTap()
        } else if !isSwallowingEscape {
            // A held Escape keeps the tap until its release is swallowed too.
            removeTap(escapeTap, escapeRunLoopSource)
            escapeTap = nil
            escapeRunLoopSource = nil
        }
    }

    private func startEscapeTap() {
        guard escapeTap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap is on the main run loop, and whether the key is dropped
            // has to be decided before the callback returns.
            let swallows = MainActor.assumeIsolated {
                service.handleEscapeTapEvent(type: type, event: event)
            }

            return swallows ? nil : Unmanaged.passUnretained(event)
        }

        // Without this tap Escape just isn't intercepted; dictation still works.
        guard let (escapeTap, escapeRunLoopSource) = makeTap(
            events: 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue,
            options: .defaultTap,
            callback: callback
        ) else {
            return
        }

        self.escapeTap = escapeTap
        self.escapeRunLoopSource = escapeRunLoopSource
    }

    /// Returns whether the event is swallowed.
    private func handleEscapeTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let escapeTap {
                CGEvent.tapEnable(tap: escapeTap, enable: true)
            }
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
                Task {
                    self.updateEscapeTap()
                }
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
            if !interceptsEscape {
                // Removed outside the tap's own callback.
                Task {
                    self.updateEscapeTap()
                }
            }
            return true

        default:
            return false
        }
    }

    private func makeTap(
        events: CGEventMask,
        options: CGEventTapOptions,
        callback: CGEventTapCallBack
    ) -> (CFMachPort, CFRunLoopSource)? {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: events,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, runLoopSource)
    }

    private func removeTap(_ tap: CFMachPort?, _ runLoopSource: CFRunLoopSource?) {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }
}

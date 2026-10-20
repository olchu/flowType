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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    func start() throws {
        guard eventTap == nil else { return }

        let events = 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in
                service.handleEvent(type: type, event: event)
            }

            return Unmanaged.passUnretained(event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(events),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.eventTapCreationFailed
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        runLoopSource = nil
        eventTap = nil
        isPressed = false
        onKeyDown = nil
        onKeyUp = nil
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
}

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
    private(set) var isRunning = false

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
        isRunning = true
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
        isRunning = false
        isPressed = false
        onKeyDown = nil
        onKeyUp = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }

        let isFnPressed = event.flags.contains(.maskSecondaryFn)

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

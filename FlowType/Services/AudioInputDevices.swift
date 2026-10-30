import CoreAudio
import Foundation

/// A device that can record. `uid` stays the same when it is unplugged and
/// after a restart, unlike `id`, so settings keep the `uid`.
struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioInputDevices {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Every connected device with input channels, by name.
    static func all() -> [AudioInputDevice] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids
            .filter(hasInput)
            .compactMap { id in
                guard
                    let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                    let name = string(kAudioObjectPropertyName, of: id)
                else {
                    return nil
                }
                return AudioInputDevice(id: id, uid: uid, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Calls `handler` on the main thread whenever a device is connected or
    /// disconnected, for as long as the app runs.
    static func onChange(_ handler: @escaping @MainActor () -> Void) {
        AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddress, .main) { _, _ in
            MainActor.assumeIsolated(handler)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }
}

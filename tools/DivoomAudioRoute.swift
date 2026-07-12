import CoreAudio
import Foundation

/// Local CoreAudio route state. CoreAudio can expose more than one live object
/// with the same human-readable Bluetooth name, so the matching objects are
/// considered as one local route: default output wins, otherwise a live match
/// means available but not selected.
enum DivoomAudioRouteState: Equatable {
    case unknown, unavailable, available, selected

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .unavailable: return "Unavailable"
        case .available: return "Available (not selected)"
        case .selected: return "Selected output"
        }
    }
}

enum DivoomAudioRoute {
    static func state(exactDeviceName name: String) -> DivoomAudioRouteState {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .unknown }
        let matches = devices().filter { deviceName($0)?.caseInsensitiveCompare(name) == .orderedSame }
        guard !matches.isEmpty else { return .unavailable }
        let liveMatches = matches.filter { uint32($0, kAudioDevicePropertyDeviceIsAlive) == 1 }
        guard !liveMatches.isEmpty else { return .unavailable }
        if let defaultDevice = defaultOutput(), liveMatches.contains(defaultDevice) { return .selected }
        return .available
    }

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var value = Array(repeating: AudioDeviceID(0), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) == noErr else { return [] }
        return value
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // Apple documents this property as returning a CFString the caller
        // owns. Keep the returned pointer in Unmanaged and consume that
        // ownership with takeRetainedValue(); using an unretained bridge was
        // incorrect and prevented reliable name matching.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

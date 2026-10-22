import CoreAudio
import CoreMediaIO
import Foundation

/// Whether any camera or microphone is in use right now, from CoreMediaIO's
/// and CoreAudio's "running somewhere" properties. Read-only; it reports live
/// use, not which apps hold the permission (macOS does not say which app).
enum PrivacyMonitor {
    struct State: Equatable {
        var camera = false
        var microphone = false
    }

    static func current() -> State {
        State(camera: anyDeviceRunning(cameraDevices(), camera: true),
              microphone: anyDeviceRunning(inputDevices(), camera: false))
    }

    // MARK: Cameras

    private static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0,
              size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0
        else { return [] }
        return devices
    }

    // MARK: Microphones

    private static func inputDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices.filter { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    private static func anyDeviceRunning(_ devices: [UInt32], camera: Bool) -> Bool {
        devices.contains { device in
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if camera {
                var address = CMIOObjectPropertyAddress(
                    mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
                var used: UInt32 = 0
                return CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &running) == 0 && running != 0
            }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
        }
    }
}

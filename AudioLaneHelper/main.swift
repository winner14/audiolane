import CoreAudio
import Foundation

func getSystemOutputDevice() -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress, 0, nil, &dataSize, &deviceID
    )
    return deviceID
}

func setSystemOutputDevice(_ deviceID: AudioDeviceID) {
    var id = deviceID
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size),
        &id
    )
}

func findBlackHoleDeviceID() -> AudioDeviceID? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)

    for id in deviceIDs {
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameRef)
        if (nameRef as String).contains("BlackHole") { return id }
    }
    return nil
}

func isDeviceConnected(_ deviceID: AudioDeviceID) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
    return deviceIDs.contains(deviceID)
}

func findBuiltInSpeaker() -> AudioDeviceID? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)

    for id in deviceIDs {
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameRef)
        let name = nameRef as String
        if name.contains("Speakers") && !name.contains("Microphone") {
            return id
        }
    }
    return nil
}

func readSavedDeviceID() -> AudioDeviceID {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let path = dir.appendingPathComponent("AudioLane/lastdevice").path
    guard let value = try? String(contentsOfFile: path, encoding: .utf8),
          let id = UInt32(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return 0
    }
    return AudioDeviceID(id)
}

func restoreAudioIfNeeded() {
    let currentDevice = getSystemOutputDevice()

    guard let blackHoleID = findBlackHoleDeviceID(),
          currentDevice == blackHoleID else {
        print("AudioLaneHelper: audio is clean")
        return
    }

    print("AudioLaneHelper: stuck on BlackHole — restoring...")
    let savedID = readSavedDeviceID()
    print("AudioLaneHelper: saved device ID = \(savedID)")

    if savedID != 0 && isDeviceConnected(savedID) {
        setSystemOutputDevice(savedID)
        print("AudioLaneHelper: restored to \(savedID)")
        return
    }

    if let speakerID = findBuiltInSpeaker() {
        setSystemOutputDevice(speakerID)
        print("AudioLaneHelper: restored to built-in speakers \(speakerID)")
        return
    }

    print("AudioLaneHelper: could not restore")
}

restoreAudioIfNeeded()
exit(0)

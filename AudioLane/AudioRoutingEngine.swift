import ScreenCaptureKit
import CoreAudio
import AVFoundation
import Foundation

@MainActor
class AudioRoutingEngine: NSObject {
    static let shared = AudioRoutingEngine()

    private var activeStreams: [pid_t: SCStream] = [:]
    private var streamOutputs: [pid_t: AppAudioStreamOutput] = [:]
    private var streamDelegate = StreamErrorDelegate()
    private var passthroughStream: SCStream?
    private var passthroughOutput: AppAudioStreamOutput?
    private var originalOutputDeviceID: AudioDeviceID?

    // MARK: - App Lifecycle

    func start() async {
        originalOutputDeviceID = getSystemOutputDevice()
        print("💾 Saved original output device: \(originalOutputDeviceID!)")

        guard let blackHoleID = findBlackHoleDeviceID() else {
            print("❌ BlackHole not found")
            return
        }
        setSystemOutputDevice(blackHoleID)
        print("✅ System output → BlackHole")

        await startPassthrough(excludingPIDs: [])
    }

    func stop() async {
        for (_, stream) in activeStreams {
            try? await stream.stopCapture()
        }
        activeStreams.removeAll()
        streamOutputs.removeAll()

        try? await passthroughStream?.stopCapture()
        passthroughStream = nil
        passthroughOutput = nil

        restoreOriginalDevice()
    }

    func restoreAudioSync() {
        restoreOriginalDevice()
        Task {
            for (_, stream) in activeStreams {
                try? await stream.stopCapture()
            }
            try? await passthroughStream?.stopCapture()
        }
    }

    // MARK: - Passthrough

    private func startPassthrough(excludingPIDs pids: [pid_t]) async {
        guard let originalID = originalOutputDeviceID else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }

            let excludedApps = content.applications.filter { pids.contains($0.processID) }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2
            config.height = 2

            let output = AppAudioStreamOutput(targetDeviceID: originalID, appName: "Passthrough")
            passthroughOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
            try stream.addStreamOutput(
                output,
                type: SCStreamOutputType.audio,
                sampleHandlerQueue: DispatchQueue(label: "audio.passthrough", qos: .userInteractive)
            )
            try await stream.startCapture()
            passthroughStream = stream
            print("✅ Passthrough started → device \(originalID), excluding \(pids.count) apps")
        } catch {
            print("❌ Passthrough failed: \(error)")
        }
    }

    private func updatePassthrough() async {
        try? await passthroughStream?.stopCapture()
        passthroughStream = nil
        passthroughOutput = nil
        await startPassthrough(excludingPIDs: Array(activeStreams.keys))
    }

    // MARK: - Per-App Routing

    func startRouting(app: RunningApp, to device: AudioDevice) async throws {
        await stopRouting(for: app)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            print("❌ No display found")
            return
        }

        let appWindows = content.windows.filter {
            $0.owningApplication?.processID == app.id && $0.isOnScreen
        }

        print("📱 Found \(appWindows.count) windows for \(app.name)")

        guard !appWindows.isEmpty else {
            print("❌ No on-screen windows for \(app.name)")
            return
        }

        let filter = SCContentFilter(display: display, including: appWindows)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2

        let output = AppAudioStreamOutput(targetDeviceID: device.id, appName: app.name)
        streamOutputs[app.id] = output

        let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
        try stream.addStreamOutput(
            output,
            type: SCStreamOutputType.audio,
            sampleHandlerQueue: DispatchQueue(label: "audio.\(app.id)", qos: .userInteractive)
        )
        try await stream.startCapture()
        activeStreams[app.id] = stream
        print("✅ Routing \(app.name) → \(device.name)")

        await updatePassthrough()
    }

    func stopRouting(for app: RunningApp) async {
        if let stream = activeStreams[app.id] {
            try? await stream.stopCapture()
            activeStreams.removeValue(forKey: app.id)
            streamOutputs.removeValue(forKey: app.id)
            print("⏹ Stopped routing \(app.name)")
            await updatePassthrough()
        }
    }

    // MARK: - CoreAudio Helpers

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

    func restoreOriginalDevice() {
        guard let originalID = originalOutputDeviceID else { return }
        setSystemOutputDevice(originalID)
        originalOutputDeviceID = nil
        print("🔊 Restored original output device: \(originalID)")
    }

    func findBlackHoleDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
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

    func findDefaultSpeaker() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
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
            if name.contains("MacBook") || name.contains("Built-in") || name.contains("Speakers") {
                return id
            }
        }
        return getSystemOutputDevice()
    }
    
    func updateOriginalDevice(_ deviceID: AudioDeviceID) {
        originalOutputDeviceID = deviceID
        print("💾 Updated original device to: \(deviceID)")
    }

    func restartPassthrough() async {
        try? await passthroughStream?.stopCapture()
        passthroughStream = nil
        passthroughOutput = nil
        await startPassthrough(excludingPIDs: Array(activeStreams.keys))
    }
}

// MARK: - Stream Output + Audio Player

class AppAudioStreamOutput: NSObject, SCStreamOutput {
    let targetDeviceID: AudioDeviceID
    let appName: String
    private var playerNode: AVAudioPlayerNode?
    private var audioEngine: AVAudioEngine?
    private let audioFormat: AVAudioFormat

    init(targetDeviceID: AudioDeviceID, appName: String) {
        self.targetDeviceID = targetDeviceID
        self.appName = appName
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        super.init()
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)

        let outputUnit = engine.outputNode.audioUnit!
        var deviceID = targetDeviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            print("❌ Failed to set output device for \(appName): \(status)")
            return
        }

        do {
            try engine.start()
            player.play()
            self.audioEngine = engine
            self.playerNode = player
            print("✅ Audio engine started for \(appName)")
        } catch {
            print("❌ Audio engine failed: \(error)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let player = playerNode else { return }
        guard let audioEngine = audioEngine, audioEngine.isRunning else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer(format: audioFormat) else { return }
        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    deinit {
        playerNode?.stop()
        audioEngine?.stop()
    }
}

// MARK: - CMSampleBuffer Extension

extension CMSampleBuffer {
    func toPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(self) else { return nil }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }

        let frameCount = UInt32(CMSampleBufferGetNumSamples(self))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let neededSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }

        let abl = bufferListPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: neededSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let ablPointer = UnsafeMutableAudioBufferListPointer(abl)
        guard let floatChannelData = pcmBuffer.floatChannelData else { return nil }

        for (channel, audioBuffer) in ablPointer.enumerated() {
            guard channel < channelCount else { break }
            guard let src = audioBuffer.mData else { continue }
            memcpy(floatChannelData[channel], src, Int(audioBuffer.mDataByteSize))
        }

        return pcmBuffer
    }
}

// MARK: - Stream Delegate

class StreamErrorDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Stream stopped: \(error)")
    }
}

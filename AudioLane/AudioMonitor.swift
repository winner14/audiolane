import CoreAudio
import Foundation
import Combine
import UserNotifications
import AppKit

@MainActor
class AudioMonitor: NSObject, ObservableObject {
    static let shared = AudioMonitor()
    private var deviceListenerAdded = false
    private var defaultDeviceListenerAdded = false
    private var permissionTimer: Timer?
    private var blackHoleVolumeListener: AudioObjectPropertyListenerBlock?

    override init() {
        super.init()
        startMonitoring()
    }

    func startMonitoring() {
        addDeviceListListener()
        addDefaultDeviceListener()
        startAppMonitoring()
        startPermissionMonitoring()
        startSleepWakeMonitoring()
        startVolumeMonitoring()
        print("Audio monitor started")
    }

    func stopMonitoring() {
        stopPermissionMonitoring()
        stopSleepWakeMonitoring()
        stopVolumeMonitoring()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        print("⏹ Audio monitor stopped")
    }
    
    // MARK: - Primary device set up
    
    func startVolumeMonitoring() {
        guard let blackHoleID = AudioRoutingEngine.shared.findBlackHoleDeviceID() else {
            print("❌ BlackHole not found for volume monitoring")
            return
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.mirrorBlackHoleVolume()
            }
        }

        AudioObjectAddPropertyListenerBlock(blackHoleID, &propertyAddress, DispatchQueue.main, listener)
        blackHoleVolumeListener = listener
        print("✅ BlackHole volume listener started")
    }

    func stopVolumeMonitoring() {
        guard let blackHoleID = AudioRoutingEngine.shared.findBlackHoleDeviceID(),
              let listener = blackHoleVolumeListener else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(blackHoleID, &propertyAddress, DispatchQueue.main, listener)
        blackHoleVolumeListener = nil
        print("⏹ BlackHole volume listener stopped")
    }

    @MainActor
    private func mirrorBlackHoleVolume() {
        guard let blackHoleID = AudioRoutingEngine.shared.findBlackHoleDeviceID() else { return }
        let primaryID = AudioManager.shared.primaryDeviceID
        guard primaryID != 0 && primaryID != blackHoleID else { return }

        // Get BlackHole's current volume
        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(blackHoleID, &propertyAddress, 0, nil, &dataSize, &volume)

        // Apply to primary device
        AudioManager.shared.setVolume(Float(volume), for: primaryID)
        print("🔊 Mirrored BlackHole volume \(Int(volume * 100))% → primary device \(primaryID)")
    }

    // MARK: - Device List Changes (device plugged/unplugged)

    private func addDeviceListListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                await self?.handleDeviceListChanged()
            }
        }

        if status == noErr {
            deviceListenerAdded = true
            print("✅ Device list listener added")
        } else {
            print("❌ Failed to add device list listener: \(status)")
        }
    }

    private func handleDeviceListChanged() async {
        print("🔌 Audio device list changed")

        let audioManager = await getAudioManager()
        let currentDeviceIDs = getCurrentDeviceIDs()

        // Check if any routed device was unplugged
        for route in audioManager.routes {
            guard let device = route.outputDevice else { continue }
            if !currentDeviceIDs.contains(device.id) {
                print("⚠️ Routed device unplugged: \(device.name) for \(route.app.name)")
                // Stop routing this app — falls back to passthrough
                await AudioRoutingEngine.shared.stopRouting(for: route.app)
                // Update the route in AudioManager
                if let index = audioManager.routes.firstIndex(where: { $0.id == route.id }) {
                    audioManager.routes[index].outputDevice = nil
                }
                // Show notification
                showNotification(
                    title: "Device Disconnected",
                    message: "\(device.name) was unplugged. \(route.app.name) is back on system default."
                )
            }
        }

        // Refresh device list in UI
        audioManager.fetchDevices()
    }

    // MARK: - Default Device Changes (Bluetooth connects/disconnects)

    private func addDefaultDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                await self?.handleDefaultDeviceChanged()
            }
        }

        if status == noErr {
            defaultDeviceListenerAdded = true
        }
    }

    private func handleDefaultDeviceChanged() async {
        let currentDefault = AudioRoutingEngine.shared.getSystemOutputDevice()

        guard let blackHoleID = AudioRoutingEngine.shared.findBlackHoleDeviceID() else { return }

        if currentDefault != blackHoleID {
            print("🔄 System default changed — updating passthrough target")

            // Save new device as the passthrough target
            AudioRoutingEngine.shared.updateOriginalDevice(currentDefault)

            // Switch back to BlackHole
            AudioRoutingEngine.shared.setSystemOutputDevice(blackHoleID)

            // Restart passthrough to use new device
            await AudioRoutingEngine.shared.restartPassthrough()

            let deviceName = getDeviceName(currentDefault)
            showNotification(
                title: "Audio Device Changed",
                message: "Now routing unassigned apps to \(deviceName)"
            )
        }
    }

    // MARK: - App Monitoring (detect when routed app quits)

    private func startAppMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }

        Task { @MainActor in
            let audioManager = await getAudioManager()
            let pid = app.processIdentifier

            // Check if this app had an active route
            if let route = audioManager.routes.first(where: { $0.app.id == pid }),
               route.outputDevice != nil {
                print("⚠️ Routed app quit: \(route.app.name)")
                await AudioRoutingEngine.shared.stopRouting(for: route.app)
            }

            // Remove from routes list
            audioManager.routes.removeAll { $0.app.id == pid }
            audioManager.runningApps.removeAll { $0.id == pid }
            
            audioManager.saveRoutes()
        }
    }

    // MARK: - Notifications

    private func showNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Helpers

    private func getCurrentDeviceIDs() -> Set<AudioDeviceID> {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &ids)
        return Set(ids)
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String {
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
        return nameRef as String
    }

    private func getAudioManager() async -> AudioManager {
        await MainActor.run {
            // Access via the shared ContentView state
            return AudioManager.shared
        }
    }

    private func removeListeners() {
        // Listeners are automatically cleaned up when the object is deallocated
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    func startSleepWakeMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        print("✅ Sleep/wake monitoring started")
    }

    @objc private func handleSleep() {
        print("😴 Mac going to sleep — restoring audio")
        AudioRoutingEngine.shared.restoreAudioSync()
    }

    @objc private func handleWake() {
        print("☀️ Mac woke up — restarting audio engine")
        Task {
            // Small delay to let macOS fully wake audio subsystem
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await AudioRoutingEngine.shared.start()
            print("✅ Audio engine restarted after wake")
        }
    }

    func stopSleepWakeMonitoring() {
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    // MARK: - Permission Monitoring

    func startPermissionMonitoring() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.permissionTimer = Timer.scheduledTimer(
                withTimeInterval: 15.0,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    do {
                        try await SCShareableContent.excludingDesktopWindows(
                            false,
                            onScreenWindowsOnly: false
                        )
                    } catch {
                        let err = error as NSError
                        if err.code == -3801 {
                            await self?.handlePermissionRevoked()
                        }
                    }
                }
            }
        }
    }

    private func handlePermissionRevoked() async {
        print("⚠️ Screen recording permission revoked")
        
        // Stop all routing
        await AudioRoutingEngine.shared.stop()
        
        // Show a gentle notification instead of a blocking alert
        let content = UNMutableNotificationContent()
        content.title = "AudioLane — Permission Required"
        content.body = "Screen Recording was disabled. Open AudioLane to re-enable routing."
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "permission-revoked",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
    
    func stopPermissionMonitoring() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

//    private func handlePermissionRevoked() async {
//        print("⚠️ Screen recording permission revoked")
//        await AudioRoutingEngine.shared.stop()
//    }
}

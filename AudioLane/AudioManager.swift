import CoreAudio
import Foundation
import Combine
import Cocoa
import ServiceManagement

struct AudioDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
    let isOutput: Bool
    let isInput: Bool
    let transportType: String // USB, Bluetooth, Built-in, etc.
}

struct AppAudioRoute: Identifiable {
    let id: pid_t  // use app pid instead of UUID
    var app: RunningApp
    var outputDevice: AudioDevice?
}

struct RunningApp: Identifiable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String
    let icon: NSImage
}

class AudioManager: NSObject, ObservableObject {
    @Published var outputDevices: [AudioDevice] = []
    @Published var primaryDeviceID: AudioDeviceID = 0
    
    static let shared = AudioManager()

    override init() {
        super.init()
        fetchDevices()
        fetchRunningApps()
        loadPrimaryDevice()
    }

    func fetchDevices() {
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

        var devices: [AudioDevice] = []

        for id in deviceIDs {
            let name = getDeviceName(id)
            let isOutput = hasOutputChannels(id)
            let isInput = hasInputChannels(id)
            let transport = getTransportType(id)

            let hiddenPrefixes = ["BlackHole", "CADefault", "ZoomAudioDevice", "Null Audio"]
            let shouldHide = hiddenPrefixes.contains(where: { name.hasPrefix($0) || name.contains($0) })

            if isOutput && !shouldHide {
                devices.append(AudioDevice(id: id, name: name, isOutput: isOutput, isInput: isInput, transportType: transport))
            }
        }

        DispatchQueue.main.async {
            self.outputDevices = devices
        }
    }
    
    func setPrimaryDevice(_ deviceID: AudioDeviceID) {
        primaryDeviceID = deviceID
        UserDefaults.standard.set(Int(deviceID), forKey: "primaryDeviceID")
//        print("Primary device set to: \(deviceID)")
    }

    func loadPrimaryDevice() {
        let saved = UserDefaults.standard.integer(forKey: "primaryDeviceID")
        if saved != 0 {
            primaryDeviceID = AudioDeviceID(saved)
        } else {
            // Default to original system output on first launch
            primaryDeviceID = AudioRoutingEngine.shared.getSystemOutputDevice()
        }
        print("Primary device loaded: \(primaryDeviceID)")
    }

    // MARK: - Helpers

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        return name as String
    }

    private func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard dataSize > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferList)

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard dataSize > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferList)

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func getTransportType(_ deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &transportType)

        switch transportType {
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Other"
        }
    }
    
    @Published var runningApps: [RunningApp] = []
    @Published var routes: [AppAudioRoute] = []

    func fetchRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&  // only normal user-facing apps
                app.localizedName != nil &&
                app.bundleIdentifier != nil
            }
            .map { app in
                RunningApp(
                    id: app.processIdentifier,
                    name: app.localizedName ?? "Unknown",
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    icon: app.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
                )
            }
            .sorted { $0.name < $1.name }

        DispatchQueue.main.async {
            self.runningApps = apps
            // Initialize routes for new apps
            for app in apps {
                if !self.routes.contains(where: { $0.app.id == app.id }) {
                    self.routes.append(AppAudioRoute(id: app.id, app: app, outputDevice: nil))
                }
            }
            // Remove routes for apps that are no longer running
            self.routes = self.routes.filter { route in
                apps.contains(where: { $0.id == route.app.id })
            }
            
            // Restore saved routes after list is ready
                self.restoreRoutes()
        }
    }

    func setDevice(_ device: AudioDevice?, for app: RunningApp) {
        if let index = routes.firstIndex(where: { $0.app.id == app.id }) {
            routes[index].outputDevice = device
        }
    }
    
    func applyRoute(_ route: AppAudioRoute) {
        print("applyRoute called for \(route.app.name) → \(route.outputDevice?.name ?? "default")")
        Task {
            do {
                if let device = route.outputDevice {
                    try await AudioRoutingEngine.shared.startRouting(app: route.app, to: device)
                } else {
                    await AudioRoutingEngine.shared.stopRouting(for: route.app)
                }
            } catch {
                print("applyRoute error: \(error)")
            }
        }
    }
    
    // MARK: - Persistence

    private let routesKey = "savedRoutes"

    func saveRoutes() {
        let data = routes.compactMap { route -> [String: Any]? in
            guard let device = route.outputDevice else { return nil }
            return [
                "appBundleID": route.app.bundleIdentifier,
                "appName": route.app.name,
                "deviceID": device.id,
                "deviceName": device.name,
                "transportType": device.transportType
            ]
        }
        UserDefaults.standard.set(data, forKey: routesKey)
        print("Saved \(data.count) routes")
    }

    func restoreRoutes() {
        guard let saved = UserDefaults.standard.array(forKey: routesKey) as? [[String: Any]] else { return }

        for entry in saved {
            guard
                let bundleID = entry["appBundleID"] as? String,
                let deviceIDRaw = entry["deviceID"] as? UInt32,
                let deviceName = entry["deviceName"] as? String,
                let transportType = entry["transportType"] as? String
            else { continue }

            // Find matching route by bundle ID
            guard let routeIndex = routes.firstIndex(where: { $0.app.bundleIdentifier == bundleID }) else {
                continue
            }

            // Check if the saved device is still connected
            guard outputDevices.contains(where: { $0.id == deviceIDRaw }) else {
                print("Saved device '\(deviceName)' no longer connected — skipping \(bundleID)")
                continue
            }

            // Restore the route
            let device = AudioDevice(
                id: deviceIDRaw,
                name: deviceName,
                isOutput: true,
                isInput: false,
                transportType: transportType
            )
            routes[routeIndex].outputDevice = device

            // Apply the route immediately
            applyRoute(routes[routeIndex])
//            print("Restored route: \(bundleID) → \(deviceName)")
        }
    }
    
    @Published var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: "launchAtLogin") {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            setLaunchAtLogin(launchAtLogin)
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.loginItem(identifier: "winner-code.AudioLaneHelper").register()
                    print("Helper registered for login")
                } else {
                    try SMAppService.loginItem(identifier: "winner-code.AudioLaneHelper").unregister()
                    print("Helper unregistered from login")
                }
            } catch {
                print("Login item error: \(error)")
            }
        }
    }

    func syncLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            let isRegistered = SMAppService.mainApp.status == .enabled
            launchAtLogin = isRegistered
        }
    }
    
    // MARK: - Volume Control

    func getVolume(for deviceID: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try main channel first
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volume)
        if status == noErr { return volume }

        // Try channel 1 if main fails
        propertyAddress.mElement = 1
        let status2 = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volume)
        if status2 == noErr { return volume }

        return nil
    }

    func setVolume(_ volume: Float, for deviceID: AudioDeviceID) {
        var vol = Float32(volume)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            UInt32(MemoryLayout<Float32>.size),
            &vol
        )

        if status != noErr {
            // Try channel 1 and 2
            propertyAddress.mElement = 1
            AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            propertyAddress.mElement = 2
            AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        }
    }

    func isMuted(_ deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &muted)
        return muted == 1
    }

    func toggleMute(for deviceID: AudioDeviceID) {
        let currentlyMuted = isMuted(deviceID)
        var muted: UInt32 = currentlyMuted ? 0 : 1
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            UInt32(MemoryLayout<UInt32>.size),
            &muted
        )
    }

    func supportsVolumeControl(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(deviceID, &propertyAddress)
    }
    
    // MARK: - Per-Device Volume Listeners

    private var volumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var volumeCallbacks: [AudioDeviceID: () -> Void] = [:]

    func startVolumeListening(for deviceID: AudioDeviceID, onChange: @escaping () -> Void) {
        // Store callback
        volumeCallbacks[deviceID] = onChange

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.volumeCallbacks[deviceID]?()
            }
        }

        AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.global(qos: .userInteractive), listener)
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.global(qos: .userInteractive), listener)

        volumeListeners[deviceID] = listener
//        print("Volume listener added for device \(deviceID)")
    }

    func stopVolumeListening(for deviceID: AudioDeviceID) {
        guard let listener = volumeListeners[deviceID] else { return }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.global(qos: .userInteractive), listener)
        AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.global(qos: .userInteractive), listener)

        volumeListeners.removeValue(forKey: deviceID)
        volumeCallbacks.removeValue(forKey: deviceID)
//        print("Volume listener removed for device \(deviceID)")
    }
    
    @Published var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: "launchAtLogin") {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            setLaunchAtLogin(launchAtLogin)
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.loginItem(identifier: "winner-code.AudioLaneHelper").register()
                    print("✅ Helper registered for login")
                } else {
                    try SMAppService.loginItem(identifier: "winner-code.AudioLaneHelper").unregister()
                    print("✅ Helper unregistered from login")
                }
            } catch {
                print("❌ Login item error: \(error)")
            }
        }
    }

    func syncLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            let isRegistered = SMAppService.mainApp.status == .enabled
            launchAtLogin = isRegistered
        }
    }
}

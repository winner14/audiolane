import Foundation
import CoreAudio
import AppKit
import Combine

enum SetupState: Equatable {
    case checking
    case ready
    case installingHomebrew
    case installingBlackHole
    case failed(String)
}

@MainActor
class SetupManager: NSObject, ObservableObject {
    static let shared = SetupManager()
    @Published var state: SetupState = .checking
    @Published var logLines: [LogLine] = []
    private var pollingTimer: Timer?

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let type: LineType
        enum LineType { case info, success, error, muted }
    }

    override init() {
        super.init()
        Task { await checkSetup() }
    }

    func checkSetup() async {
        state = .checking
        try? await Task.sleep(nanoseconds: 500_000_000)
        if isBlackHoleInstalled() {
            state = .ready
        } else {
            await startInstall()
        }
    }

    // MARK: - Auto Install

    func startInstall() async {
        logLines = []
        state = .installingBlackHole
        log("Opening Terminal to install BlackHole...", .info)
        log("Please enter your password when Terminal asks.", .info)
        
        let brewPath = getBrewPath() ?? "/opt/homebrew/bin/brew"
        let command: String
        
        if isHomebrewInstalled() {
            command = "\(brewPath) install blackhole-2ch && echo '✅ BlackHole installed successfully'"
        } else {
            command = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" && \(brewPath) install blackhole-2ch && echo '✅ Done'"
        }
        
        openTerminalWithCommand(command)
        
        // Start polling — auto-detect when BlackHole appears
        log("Waiting for installation to complete...", .info)
        log("Keep the Terminal window open until it finishes.", .muted)
        startPolling()
    }

    private func openTerminalWithCommand(_ command: String) {
        // Method 1 — Launch Terminal via NSWorkspace then send command
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            if let error = error {
                print("❌ Could not open Terminal: \(error)")
                self?.fallbackToCopyCommand(command)
                return
            }
            
            // Wait for Terminal to launch then send the command
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let script = """
                tell application "Terminal"
                    activate
                    do script "\(command)"
                end tell
                """
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                if let error = error {
                    print("❌ AppleScript after launch: \(error)")
                    self?.fallbackToCopyCommand(command)
                }
            }
        }
    }

    private func fallbackToCopyCommand(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        
        DispatchQueue.main.async {
            self.log("Command copied to clipboard ✓", .success)
            self.log("Open Terminal and paste with Cmd+V", .info)
            self.log("AudioLane will detect completion automatically.", .muted)
        }
    }
    
    private func installBlackHole() async {
        state = .installingBlackHole
        log("Installing BlackHole virtual audio driver...", .info)

        let brewPath = getBrewPath() ?? "/opt/homebrew/bin/brew"
        let realHome = getRealHomeDirectory()
        let success = await runInstaller(
            command: "HOME=\(realHome) \(brewPath) install blackhole-2ch"
        )
        print("🏠 Real HOME: \(realHome)")

        if success {
            log("BlackHole installed ✓", .success)
            log("Verifying audio driver...", .info)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if isBlackHoleInstalled() {
                log("Audio driver detected ✓", .success)
                state = .ready
            } else {
                log("Driver installed — restarting audio engine...", .info)
                restartCoreAudio()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if isBlackHoleInstalled() {
                    log("Audio driver detected ✓", .success)
                    state = .ready
                } else {
                    log("Please restart your Mac to complete setup.", .muted)
                    state = .failed("Restart required to activate audio driver.")
                }
            }
        } else {
            log("BlackHole install failed", .error)
            state = .failed("Could not install BlackHole automatically.")
        }
    }

    // MARK: - Process Runner

    private func runInstaller(command: String) async -> Bool {
        print("🚀 Running: \(command)")
        
        return await withCheckedContinuation { continuation in
            var resumed = false
            
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges"]
                
                let pipe = Pipe()
                let errorPipe = Pipe()
                task.standardOutput = pipe
                task.standardError = errorPipe
                
                task.terminationHandler = { process in
                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    
                    print("✅ Exit code: \(process.terminationStatus)")
                    print("📤 Output: \(output)")
                    print("📤 Error: \(errorOutput)")
                    
                    DispatchQueue.main.async {
                        guard !resumed else { return }
                        resumed = true
                        
                        if process.terminationStatus == 0 {
                            if !output.isEmpty {
                                output.components(separatedBy: "\n")
                                    .filter { !$0.isEmpty }
                                    .suffix(5)
                                    .forEach { self.log($0, .muted) }
                            }
                            continuation.resume(returning: true)
                        } else {
                            if errorOutput.contains("cancelled") || errorOutput.contains("canceled") {
                                self.log("Installation cancelled — click Try Again when ready", .error)
                            } else if errorOutput.contains("password") {
                                self.log("Incorrect password — please try again", .error)
                            } else {
                                self.log("Error: \(errorOutput)", .error)
                            }
                            continuation.resume(returning: false)
                        }
                    }
                }
                
                do {
                    try task.run()
                    print("🚀 osascript launched — waiting...")
                } catch {
                    print("❌ Failed to launch osascript: \(error)")
                    DispatchQueue.main.async {
                        guard !resumed else { return }
                        resumed = true
                        self.log("Failed to launch installer: \(error.localizedDescription)", .error)
                        continuation.resume(returning: false)
                    }
                }
            }
            
            // Timeout after 3 minutes
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                guard !resumed else { return }
                print("⏰ Timed out")
                resumed = true
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Helpers

    private func isHomebrewInstalled() -> Bool {
        return getBrewPath() != nil
    }

    private func getBrewPath() -> String? {
        let paths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }
    
    private func getRealHomeDirectory() -> String {
        // Get the real home directory, not the container path
        let pw = getpwuid(getuid())
        if let pw = pw, let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        // Fallback — strip the container path
        let containerHome = NSHomeDirectory()
        if containerHome.contains("/Containers/") {
            let realHome = "/Users/" + containerHome.components(separatedBy: "/").dropFirst(2).first!
            return realHome
        }
        return containerHome
    }

    private func restartCoreAudio() {
        let script = NSAppleScript(source: "do shell script \"killall coreaudiod\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    func isBlackHoleInstalled() -> Bool {
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
            if (nameRef as String).contains("BlackHole") { return true }
        }
        return false
    }

    private func log(_ text: String, _ type: LogLine.LineType) {
        logLines.append(LogLine(text: text, type: type))
    }

    func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isBlackHoleInstalled() {
                self.pollingTimer?.invalidate()
                self.state = .ready
            }
        }
    }
}

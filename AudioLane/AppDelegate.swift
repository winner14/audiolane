import AppKit
import SwiftUI
import ScreenCaptureKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    private var routingObserver: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        updateMenuBarIcon(activeRoutes: 0)

        // Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover

        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            print(granted ? "✅ Notifications allowed" : "⚠️ Notifications denied")
        }
        
        // Monitor for clicks outside the popover
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.popover?.performClose(nil)
            }
        }

        // Start engine and monitor
        Task {
            await AudioRoutingEngine.shared.start()
            AudioMonitor.shared.startMonitoring()
        }

        // Request screen capture permission
        Task {
            try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }

        // Observe route changes to update menu bar icon
        startObservingRoutes()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioMonitor.shared.stopMonitoring()
        AudioRoutingEngine.shared.restoreAudioSync()
    }

    // MARK: - Popover

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Menu Bar Icon

    private func startObservingRoutes() {
        // Poll every second to update icon based on active routes
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            let activeCount = AudioManager.shared.routes.filter { $0.outputDevice != nil }.count
            DispatchQueue.main.async {
                self?.updateMenuBarIcon(activeRoutes: activeCount)
            }
        }
    }

    func updateMenuBarIcon(activeRoutes: Int) {
        guard let button = statusItem?.button else { return }

        if activeRoutes == 0 {
            // No active routes — simple icon
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "AudioLane")?
                .withSymbolConfiguration(config)
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            // Active routes — show icon + count badge
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(.init(paletteColors: [.controlAccentColor]))
            button.image = NSImage(systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "Audio Router")?
                .withSymbolConfiguration(config)
            button.title = " \(activeRoutes)"
            button.imagePosition = .imageLeft
        }

        // Tooltip
        button.toolTip = activeRoutes == 0
            ? "Audio Router — No active routes"
            : "Audio Router — \(activeRoutes) active \(activeRoutes == 1 ? "route" : "routes")"
    }
}

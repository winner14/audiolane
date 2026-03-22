import SwiftUI

struct ContentView: View {
    @StateObject private var audioManager = AudioManager.shared
    @StateObject private var setup = SetupManager.shared
    @State private var selectedTab: Tab = .routes
    @State private var appeared = false

    enum Tab { case routes, devices }

    var body: some View {
        if case .ready = setup.state {
            mainView
        } else {
            SetupView(setup: setup)
        }
    }

    var mainView: some View {
        ZStack {
            // Background
            Color(red: 0.08, green: 0.08, blue: 0.10)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                tabBar
                Divider()
                    .background(Color.white.opacity(0.06))
                content
                footer
            }
        }
        .frame(width: 400)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Header
    var header: some View {
        HStack(spacing: 10) {
            // Animated waveform icon
            HStack(spacing: 2) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(red: 0.4, green: 0.8, blue: 1.0))
                        .frame(width: 3, height: appeared ? [8.0, 14.0, 10.0, 6.0][i] : 4)
                        .animation(
                            .easeInOut(duration: 0.8)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                            value: appeared
                        )
                }
            }
            .frame(width: 20, height: 16)
            .onAppear { appeared = true }

            Text("AUDIOLANE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .tracking(3)

            Spacer()

            // Status pill
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: .green, radius: 3)
                Text("ACTIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .tracking(1.5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.1))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.green.opacity(0.3), lineWidth: 0.5))

            // Refresh button
            Button(action: {
                audioManager.fetchDevices()
                audioManager.fetchRunningApps()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Refresh devices and apps")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Tab Bar
    var tabBar: some View {
        HStack(spacing: 0) {
            TabButton(title: "APPLICATIONS", icon: "arrow.triangle.branch", isSelected: selectedTab == .routes) {
                selectedTab = .routes
            }
            TabButton(title: "DEVICES", icon: "hifispeaker.2", isSelected: selectedTab == .devices) {
                selectedTab = .devices
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Content
    var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                if selectedTab == .routes {
                    if audioManager.routes.isEmpty {
                        emptyState(icon: "app.dashed", message: "No apps running")
                    } else {
                        ForEach(audioManager.routes.indices, id: \.self) { index in
                            AppRouteRow(
                                route: audioManager.routes[index],
                                devices: audioManager.outputDevices,
                                onDeviceSelected: { device in
                                    audioManager.routes[index].outputDevice = device
                                    audioManager.applyRoute(audioManager.routes[index])
                                    audioManager.saveRoutes()
                                }
                            )
                        }
                    }
                } else {
                    if audioManager.outputDevices.isEmpty {
                        emptyState(icon: "speaker.slash", message: "No output devices found")
                    } else {
                        ForEach(audioManager.outputDevices) { device in
                            DeviceRow(device: device, audioManager: audioManager)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 380)
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }

    // MARK: - Footer
    var footer: some View {
        HStack {
            // Active routes count
            let activeCount = audioManager.routes.filter { $0.outputDevice != nil }.count
            HStack(spacing: 4) {
                Text("\(activeCount)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(activeCount > 0 ? Color(red: 0.4, green: 0.8, blue: 1.0) : .white.opacity(0.3))
                Text(activeCount == 1 ? "ROUTE ACTIVE" : "ROUTES ACTIVE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(1)
            }

            Spacer()

            Button("QUIT") {
                Task {
                    await AudioRoutingEngine.shared.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
            .tracking(1.5)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.15))
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Tab Button
struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.5)
            }
            .foregroundColor(isSelected ? Color(red: 0.4, green: 0.8, blue: 1.0) : .white.opacity(0.3))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.3) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Route Row
struct AppRouteRow: View {
    let route: AppAudioRoute
    let devices: [AudioDevice]
    let onDeviceSelected: (AudioDevice?) -> Void
    @State private var isHovered = false

    var isRouted: Bool { route.outputDevice != nil }

    var body: some View {
        HStack(spacing: 12) {
            // App icon
            Image(nsImage: route.app.icon)
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isRouted ? 1.0 : 0.6)

            // App info
            VStack(alignment: .leading, spacing: 2) {
                Text(route.app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if isRouted {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color(red: 0.4, green: 0.8, blue: 1.0))
                        Text(route.outputDevice!.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(red: 0.4, green: 0.8, blue: 1.0))
                            .lineLimit(1)
                    } else {
                        Text("System Default")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
            }

            Spacer()

            // Device picker
            Menu {
                Button {
                    onDeviceSelected(nil)
                } label: {
                    HStack {
                        Text("System Default")
                        if !isRouted { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                ForEach(devices) { device in
                    Button {
                        onDeviceSelected(device)
                    } label: {
                        HStack {
                            Image(systemName: iconForTransport(device.transportType))
                            Text(device.name)
                            if route.outputDevice?.id == device.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isRouted ? iconForTransport(route.outputDevice!.transportType) : "speaker.wave.2")
                        .font(.system(size: 10))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(isRouted ? Color(red: 0.4, green: 0.8, blue: 1.0) : .white.opacity(0.3))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(isRouted ? Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.1) : Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRouted ? Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.3) : Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRouted ? Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.2) : Color.white.opacity(0.05), lineWidth: 0.5)
                )
        )
        .onHover { isHovered = $0 }
    }

    func iconForTransport(_ type: String) -> String {
        switch type {
        case "Bluetooth": return "headphones"
        case "Built-in": return "laptopcomputer"
        case "USB": return "cable.connector"
        case "HDMI", "DisplayPort": return "tv"
        case "AirPlay": return "airplayaudio"
        default: return "speaker.wave.2"
        }
    }
}

// MARK: - Device Row
struct DeviceRow: View {
    let device: AudioDevice
    @ObservedObject var audioManager: AudioManager
    @State private var isExpanded = false
    @State private var volume: Float = 0.75
    @State private var isMuted = false

    var isPrimary: Bool {
        audioManager.primaryDeviceID == device.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Device icon
                Image(systemName: iconForTransport(device.transportType))
                    .font(.system(size: 14))
                    .foregroundColor(isExpanded ? Color(red: 0.4, green: 0.8, blue: 1.0) : .white.opacity(0.6))
                    .frame(width: 28)

                // Device info
                VStack(alignment: .leading, spacing: 2) {
                    if audioManager.supportsVolumeControl(device.id) {
                        Text(isMuted ? "Muted" : "\(Int(volume * 100))%")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(isMuted ? Color(red: 1.0, green: 0.4, blue: 0.4) : Color(red: 0.4, green: 0.8, blue: 1.0))
                            .tracking(1)
                    }

                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))

                    Text(device.transportType.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.25))
                        .tracking(1.5)
                }

                Spacer()

                // Star — set as primary
                Button(action: {
                    audioManager.setPrimaryDevice(device.id)
                }) {
                    Image(systemName: isPrimary ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundColor(isPrimary ? Color(red: 1.0, green: 0.85, blue: 0.3) : .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help(isPrimary ? "Primary device — keyboard volume controls this" : "Set as primary device")

                // Expand chevron
                if audioManager.supportsVolumeControl(device.id) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.3))
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if audioManager.supportsVolumeControl(device.id) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded volume panel
            if isExpanded && audioManager.supportsVolumeControl(device.id) {
                VStack(spacing: 8) {
                    Divider()
                        .background(Color.white.opacity(0.06))

                    HStack(spacing: 10) {
                        Button(action: {
                            audioManager.toggleMute(for: device.id)
                            isMuted = audioManager.isMuted(device.id)
                        }) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                                .font(.system(size: 11))
                                .foregroundColor(isMuted ? Color(red: 1.0, green: 0.4, blue: 0.4) : .white.opacity(0.5))
                                .frame(width: 24)
                        }
                        .buttonStyle(.plain)

                        Slider(value: Binding(
                            get: { Double(volume) },
                            set: { newValue in
                                volume = Float(newValue)
                                audioManager.setVolume(volume, for: device.id)
                                if isMuted && volume > 0 {
                                    audioManager.toggleMute(for: device.id)
                                    isMuted = false
                                }
                            }
                        ), in: 0...1)
                        .tint(Color(red: 0.4, green: 0.8, blue: 1.0))

                        Image(systemName: volume > 0.5 ? "speaker.wave.3.fill" : volume > 0 ? "speaker.wave.1.fill" : "speaker.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 24)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPrimary ? Color(red: 1.0, green: 0.85, blue: 0.3).opacity(0.05) : isExpanded ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isPrimary ? Color(red: 1.0, green: 0.85, blue: 0.3).opacity(0.25) : isExpanded ? Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.3) : Color.white.opacity(0.05), lineWidth: 0.5)
                )
        )
        .onAppear {
            volume = audioManager.getVolume(for: device.id) ?? 0.75
            isMuted = audioManager.isMuted(device.id)
            audioManager.startVolumeListening(for: device.id) {
                volume = audioManager.getVolume(for: device.id) ?? volume
                isMuted = audioManager.isMuted(device.id)
            }
        }
        .onDisappear {
                    audioManager.stopVolumeListening(for: device.id)
                }

    }

    func iconForTransport(_ type: String) -> String {
        switch type {
        case "Bluetooth": return "headphones"
        case "Built-in": return "laptopcomputer"
        case "USB": return "cable.connector"
        case "HDMI", "DisplayPort": return "tv"
        case "AirPlay": return "airplayaudio"
        default: return "speaker.wave.2"
        }
    }
}

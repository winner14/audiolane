import SwiftUI

struct SetupView: View {
    @ObservedObject var setup: SetupManager
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.06))
                content
                Divider().background(Color.white.opacity(0.06))
                footer
            }
        }
        .frame(width: 420)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Header
    var header: some View {
        HStack(spacing: 10) {
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

            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    var statusPill: some View {
        Group {
            switch setup.state {
            case .checking:
                pill(text: "CHECKING", color: .orange)
            case .installingHomebrew:
                pill(text: "INSTALLING HOMEBREW", color: .orange)
            case .installingBlackHole:
                pill(text: "INSTALLING DRIVER", color: .blue)
            case .failed:
                pill(text: "FAILED", color: .red)
            case .ready:
                pill(text: "READY", color: .green)
            }
        }
    }

    func pill(text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .tracking(1.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: - Content
    @ViewBuilder
    var content: some View {
        switch setup.state {
        case .checking:
            checkingView

        case .installingHomebrew, .installingBlackHole:
            installingView

        case .failed(let reason):
            failedView(reason: reason)

        case .ready:
            EmptyView()
        }
    }

    var checkingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.7)
                .tint(Color(red: 0.4, green: 0.8, blue: 1.0))
                .frame(width: 16, height: 16)
            Text("CHECKING DEPENDENCIES")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(50)
    }

    var installingView: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Color(red: 0.4, green: 0.8, blue: 1.0))
                    .frame(width: 16, height: 16)
                Text("Waiting for BlackHole installation...")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }

            // Log output
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(setup.logLines) { line in
                            Text(line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(logColor(line.type))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 120)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                .onChange(of: setup.logLines.count) { _ in
                    if let last = setup.logLines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // Step indicators
            VStack(alignment: .leading, spacing: 8) {
                StepIndicator(number: 1, text: "Terminal opened automatically", isDone: true)
                StepIndicator(number: 2, text: "Enter your Mac password when asked", isDone: false)
                StepIndicator(number: 3, text: "AudioLane will detect completion automatically", isDone: false)
            }

            Text("This screen will update automatically when done.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
        }
        .padding(16)
    }

    func failedView(reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 36))
                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))

            Text(reason)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Manual fallback
            VStack(alignment: .leading, spacing: 8) {
                Text("INSTALL MANUALLY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.25))
                    .tracking(2)

                manualCommand(command: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
                manualCommand(command: "brew install blackhole-2ch")
            }

            Button(action: { Task { await setup.startInstall() } }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("TRY AGAIN")
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(Color(red: 0.4, green: 0.8, blue: 1.0))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }

    func manualCommand(command: String) -> some View {
        HStack(spacing: 0) {
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.4, green: 1.0, blue: 0.6))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.4))
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.05))
            }
            .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: - Footer
    var footer: some View {
        HStack {
            Spacer()
            Button("QUIT") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                .tracking(1.5)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    func logColor(_ type: SetupManager.LogLine.LineType) -> Color {
        switch type {
        case .success: return Color(red: 0.4, green: 1.0, blue: 0.6)
        case .error: return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .info: return Color(red: 0.4, green: 0.8, blue: 1.0)
        case .muted: return .white.opacity(0.2)
        }
    }
    
    struct StepIndicator: View {
        let number: Int
        let text: String
        let isDone: Bool

        var body: some View {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isDone ? Color(red: 0.4, green: 1.0, blue: 0.6).opacity(0.15) : Color.white.opacity(0.05))
                        .frame(width: 20, height: 20)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(red: 0.4, green: 1.0, blue: 0.6))
                    } else {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(isDone ? .white.opacity(0.6) : .white.opacity(0.3))
            }
        }
    }
}

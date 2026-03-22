# AudioLane

macOS menu bar utility that intercepts and routes per-app audio streams to independent output devices using BlackHole and ScreenCaptureKit.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![License](https://img.shields.io/badge/license-MIT-green)

---

## What it does

AudioLane lets you send different apps to different audio output devices simultaneously. Play music through your speakers while watching a YouTube video through your headphones — all managed from a clean menu bar interface.

- Route any running app to any connected output device
- Unrouted apps continue playing through your system default device
- Routes are saved and restored between sessions
- Automatically restores your audio setup when the app closes

---

## Requirements

- macOS 14.0 (Sonoma) or later
- [Homebrew](https://brew.sh)
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) — a free virtual audio driver

---

## Installation

Install everything with two commands:
```bash
brew tap winner14/audiolane
brew install --cask audiolane
```

BlackHole will be installed automatically as part of the process.

### Updating

To update AudioLane to the latest version:
```bash
brew upgrade --cask audiolane
```

### First launch

Since AudioLane is not yet notarized, macOS will show a security warning on first launch.

To open it:
1. Go to **System Settings → Privacy & Security**
2. Scroll down to find **"AudioLane was blocked"**
3. Click **Open Anyway**
4. Enter your password

This is a one-time step.

### Screen Recording permission

AudioLane requires Screen Recording permission to capture and route app audio. On first launch you will be prompted to grant this — click **Allow**.

If you accidentally denied it:
1. Go to **System Settings → Privacy & Security → Screen Recording**
2. Find AudioLane and toggle it **on**
3. **Quit and relaunch** AudioLane — this step is required

---

## How to use

1. Click the AudioLane icon in your menu bar
2. Under **App Routes**, find the app you want to route
3. Click the chevron (⌃⌄) next to it and select an output device
4. Audio from that app will now play exclusively through the chosen device

To stop routing an app, select **System Default** from its device picker.

The menu bar icon shows how many routes are currently active.

---

## Uninstall
```bash
brew uninstall --cask audiolane
brew untap winner14/audiolane
```

Your system audio will be fully restored on uninstall.

To also remove BlackHole:
```bash
brew uninstall --cask blackhole-2ch
```

---

## Troubleshooting

### No audio after quitting AudioLane
AudioLane may not have restored your system output device correctly. Fix it manually:

1. Go to **System Settings → Sound → Output**
2. Select your preferred output device

Or run:
```bash
# Restart the audio daemon
sudo killall coreaudiod
```

### BlackHole not detected after install
macOS needs to reload its audio drivers after BlackHole installs. Try:
```bash
sudo killall coreaudiod
```

If that doesn't work, a full restart will always resolve it:

**Apple menu → Restart**

### App stuck on "Checking dependencies"
BlackHole may be installed but not yet registered. Run:
```bash
system_profiler SPAudioDataType | grep -i blackhole
```

If BlackHole appears in the output, restart CoreAudio:
```bash
sudo killall coreaudiod
```

Then relaunch AudioLane.

### Audio playing through wrong device / double audio
This can happen if AudioLane was force-quit without cleaning up. Fix it:

1. Open AudioLane
2. Click **Reset Audio** in the footer
3. Or go to **System Settings → Sound → Output** and manually select your device

### Screen Recording permission keeps getting revoked
This can happen after macOS updates. Re-grant it:

1. **System Settings → Privacy & Security → Screen Recording**
2. Toggle AudioLane off and back on
3. **Quit and relaunch** AudioLane

### Routes not being applied after relaunch
If a previously routed device is no longer connected, AudioLane skips that route automatically. Reconnect the device and reopen the app — routes will restore.

### "AudioLane can't be opened because Apple cannot verify it"
See the **First launch** section above — go to **System Settings → Privacy & Security → Open Anyway**.

---

## How it works

AudioLane uses two macOS frameworks:

**ScreenCaptureKit** captures the audio output of individual apps. When you assign an app to a device, AudioLane starts a capture stream for that app and plays its audio through an `AVAudioEngine` instance pointed at the chosen device.

**BlackHole** acts as a virtual sink — AudioLane sets it as the system default output so all audio flows through it, then routes each captured stream to its assigned device. Unrouted apps are captured at the display level and played through your original system default device.

When AudioLane quits, it restores your original system output device automatically.

---

## Tech stack

- Swift + SwiftUI
- ScreenCaptureKit (per-app audio capture)
- CoreAudio (device enumeration and routing)
- AVFoundation (audio playback engine)
- BlackHole 2ch (virtual audio driver)

---

## Roadmap

- [ ] Bundled audio driver (no BlackHole dependency)
- [ ] Volume control per route
- [ ] App Store distribution
- [ ] Sleep/wake stream recovery
- [ ] Menu bar audio level indicators

---

## License

MIT

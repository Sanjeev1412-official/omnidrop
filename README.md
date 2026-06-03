# OmniDrop 🌐📁

OmniDrop is a decentralized, zero-configuration file sharing and data-messaging ecosystem designed to eliminate cross-platform local file sharing friction between Windows and Android devices.

By combining Acoustic Proximity Handshaking with low-overhead, hardware-accelerated WebRTC DataChannel Pipelines, OmniDrop circumvents traditional ecosystem restrictions (like Apple AirDrop or Windows Quick Share limitations) and completely breaks network boundaries.

---

## ✨ Key Features

*   **True Cross-Platform Compatibility:** Seamlessly share files and data between Windows and Android without ecosystem lock-in.
*   **Zero-Configuration Discovery:** Utilizes Acoustic Proximity Handshaking to automatically discover and pair devices without relying on complex Wi-Fi or Bluetooth configurations.
*   **High-Speed Decentralized Transfers:** Built on low-overhead, hardware-accelerated WebRTC DataChannel Pipelines for blazing-fast, peer-to-peer data messaging.
*   **Deep Android Integration:** Features native Android capabilities, including a Quick Settings Tile (`OmniDropTileService`) for instant access from the notification shade and stable background service execution (`StartServiceActivity`).

---

## 🏗️ Technical Architecture & Codebase

Based on the repository structure, OmniDrop utilizes a cross-platform framework paired with native Kotlin code to achieve deep Android OS integration:

*   **Core Engine:** WebRTC DataChannels handle the peer-to-peer data pipeline, bypassing standard network restrictions.
*   **Discovery Layer:** Acoustic Handshaking allows devices in physical proximity to find each other effortlessly.
*   **Native Android Layer (`android/app/src/main/kotlin/com/example/omnidrop/`):** 
    *   `MainActivity.kt`: The primary application entry point.
    *   `OmniDropTileService.kt`: Implements the custom Android Quick Settings tile UI (`ic_qs_omnidrop.png`).
    *   `StartServiceActivity.kt`: Manages persistent background execution (`ic_bg_service_small.png`) to ensure file transfers remain stable even when the app is minimized.

---

## 🚀 Getting Started

### Prerequisites
*   Flutter SDK (Recommended for the cross-platform UI)
*   Android Studio (for compiling the Android Kotlin services)
*   Visual Studio 2022 (for compiling the Windows desktop client)

### Installation & Execution

1. **Clone the repository:**
```bash
   git clone [https://github.com/your-username/omnidrop.git](https://github.com/your-username/omnidrop.git)
   cd omnidrop
```
Install dependencies:

```bash
   flutter pub get
```
Run on Android:
Connect your Android device (with USB Debugging enabled) and run:

```bash
   flutter run -d android
```
Run on Windows:

```bash
   flutter run -d windows
```

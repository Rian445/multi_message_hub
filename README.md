# Multi-Message Hub 💬

A native Android application built with Flutter and Kotlin that enables running **multiple simultaneous, completely isolated Google Messages for Web accounts** on a single device. Designed for users with multiple SIM cards, multiple physical phones, or work/personal numbers who want unified SMS/RCS management without switching profiles or carrying multiple devices.

---

## 🛡️ Security & Privacy Architecture

Multi-Message Hub is built with a zero-compromise approach to privacy, local data sovereignty, and credential isolation.

### 1. Multi-Profile WebKit Sandboxing (`androidx.webkit:webkit`)
* Each paired phone/SIM instance runs in its own cryptographically distinct **WebKit Storage Profile** via `ProfileStore.getInstance().getOrCreateProfile(uuid)`.
* **Complete Session Separation**: Cookies, IndexedDB databases, Cache, Service Workers, and LocalStorage for Device A are strictly isolated from Device B. There is zero state leakage or token collisions between accounts.
* When a device profile is deleted, its entire profile cache, storage, and cookie jar are purged directly at the native WebKit engine level.

### 2. Android OS-Level Process & Storage Isolation
* **Linux UID Sandboxing**: Android assigns a unique Linux User ID (UID) exclusively to this application. All internal files, WebKit databases, and pairing tokens live in `/data/data/com.multimessenger.hub.multi_message_hub/` under strict `0700` (`rwx------`) permissions.
* **SELinux Enforcement**: Mandatory Access Control (MAC) prevents non-system apps from injecting code or reading process memory. **No third-party app installed on your phone can read or extract your message sessions.**

### 3. Anti-Extraction & Backup Hardening
* **`android:allowBackup="false"`**: Completely disables ADB USB backup dumps (`adb backup`) and automated cloud clones (Google Drive device migration). Your pairing keys and cookies cannot be cloned to a computer or another device via USB.
* **`android:usesCleartextTraffic="false"`**: Rejects all unencrypted (HTTP) traffic. 100% of communication is strictly encrypted over TLS (HTTPS/WSS).

### 4. Strict Navigation Domain Whitelisting
* The embedded WebViews are hard-locked to official Google domains:
  - `messages.google.com`
  - `accounts.google.com` / `myaccount.google.com`
  - `*.google.com`, `*.google`, `*.gstatic.com`, `*.googleusercontent.com`
* **Safe External Forwarding**: Any external URL (such as a link shared in a chat, help link, or tracking script) is **strictly forbidden** from loading inside the isolated WebView container. It is instead forwarded safely to the device's external web browser.

### 5. Hardware-Backed App Lock (PIN & Biometrics)
* **Biometric Authentication**: Fingerprint and Face Unlock support powered by Android `BiometricPrompt` and `FlutterFragmentActivity`.
* **4-Digit Master PIN**: Hardware-backed numeric passcode protection.
* **Auto-Lock on Background**: If the app is minimized or backgrounded for more than 2 seconds, it automatically re-engages the lock screen, shielding open chats from prying eyes.

### 6. Zero Telemetry & Zero Proxy Servers
* **100% Direct Google Connection**: Network traffic travels directly between your phone and Google's official servers.
* **No Middleman**: Zero third-party proxies, analytics, crash-loggers, or telemetry SDKs are included. Your messages are never relayed through external servers.

---

## ⚡ Key Features

* **Unlimited Simultaneous Google Messages Accounts**: Pair multiple physical phones or SIM cards side-by-side.
* **Dual Pairing Support**: Full support for both **QR Code Scanning** and **Google Account Sign-In** with emoji verification.
* **Native Notification Interception**: Real-time JavaScript DOM observer intercepts incoming SMS/RCS alerts and delivers native Android notifications with direct profile-switch on tap.
* **Custom SMS Status Bar Icon**: Crisp, monochrome SMS speech bubble notification icon that adheres to Android 5.0+ status bar guidelines.
* **Configurable Background Sync**: Toggle persistent foreground notifications ON or OFF in Settings according to your preference.
* **Responsive Display Modes**: Instant one-tap toggle between **Phone View (Mobile Fit)** and **Web View (Desktop UI)**.
* **Google Messages Dark UI**: High-contrast, battery-friendly dark theme (`#1E1F22` / `#131314`) matching official Google design language.
* **Unified Drawer & Settings**: Intuitive side drawer with device switching, unread counters, and consolidated Settings.

---

## ⚙️ Performance & Low-End Device Optimization

* **Idle CPU ~0%**: Notifications use event-driven WebSockets rather than HTTP polling. Background helper scripts self-terminate within 10–12 seconds after page load to eliminate redundant CPU cycles.
* **Low Memory Footprint**: Uses ~140 MB – 180 MB of RAM for multiple active sessions, easily running on entry-level Android devices with 2 GB – 3 GB RAM.
* **Local Web Caching (`LOAD_DEFAULT`)**: Scripts and UI assets are cached on local storage, preventing re-downloading Google Messages bundles on launch.
* **Hardware Acceleration**: Full GPU hardware acceleration enabled for smooth 60+ FPS navigation.

---

## 📱 Developer & Project Info

* **Lead Developer**: **MajorThug**
* **Application Name**: Multi-Message Hub
* **Current Version**: `1.0.0 (Release Build)`
* **Target Platform**: Android 8.0+ (API Level 26+)
* **Engine Architecture**: Flutter + AndroidX WebKit Multi-Profile (`androidx.webkit:webkit:1.12.1`)

---

## 🛠️ Building & Installation

### Prerequisites
* Flutter SDK (3.11.1+)
* Android SDK (API 26+)
* Java / JDK 17+

### Build Release APK
```bash
flutter pub get
flutter build apk --release
```

The production APK will be generated at:
```
build/app/outputs/flutter-apk/app-release.apk
```

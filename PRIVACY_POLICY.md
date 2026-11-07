# Security & Privacy Policy

**Effective Date:** November 2026  
**Application:** Multi-Message Hub  
**Developer:** MajorThug  

---

## 1. Core Commitment & Privacy Philosophy
**Multi-Message Hub is built on a zero-compromise, local-only architecture.**  
We firmly believe your messages, private SMS/RCS conversations, pairing credentials, and device data belong exclusively to you. 

* **Zero Data Collection**: We do not collect, harvest, analyze, or monetize your personal information or messages.
* **No Middleman Servers**: Multi-Message Hub does not operate any intermediary proxy, relay, or cloud storage server. All web communication travels directly and securely between your device and Google's official endpoints (`messages.google.com`).
* **Zero 3rd-Party SDKs / Analytics**: The app contains zero analytics engines (no Google Analytics, Firebase Analytics, Adjust, AppsFlyer), zero advertising networks, and zero telemetry loggers.

---

## 2. Protection Against Third-Party Apps (OS-Level Isolation)
A primary concern for users is whether other apps installed on their Android device (e.g. social media, utility apps, malicious third-party apps) can view or siphon their messages.

**They cannot.** Protection is enforced at the Android Operating System and Linux Kernel levels:

1. **Linux User ID (UID) Sandboxing**:
   - Android assigns a unique Linux UID (e.g., `u0_a245`) exclusively to Multi-Message Hub.
   - All session tokens, cookies, chat databases, and WebKit storage live inside `/data/data/com.multimessenger.hub.multi_message_hub/` with strict POSIX permissions `drwx------` (`0700`).
   - The Linux kernel strictly blocks any third-party app from reading, accessing, or modifying these directories.
2. **SELinux Mandatory Access Control**:
   - SELinux prevents external processes from inspecting app memory or executing cross-process injections.
3. **No Exported Content Providers or Vulnerable Receivers**:
   - The app does not expose any ContentProvider, service, or broadcast receiver to other applications.

---

## 3. Account & Multi-Profile Storage Isolation
Multi-Message Hub uses native AndroidX WebKit multi-profile architecture (`androidx.webkit:webkit`):
* **Profile Sandboxing**: Each paired account or SIM runs inside its own cryptographically distinct storage container via `ProfileStore.getInstance().getOrCreateProfile(profileUuid)`.
* **Zero Cross-Account Bleed**: Cookies, IndexedDB, Cache, LocalStorage, and Service Workers for Profile A are completely inaccessible to Profile B.
* **Instant Complete Purge**: When you delete a profile from the app, its entire cookie jar, local database, and cached data are permanently deleted from native storage.

---

## 4. Network Security & Domain Pinning
* **Enforced TLS/HTTPS (`android:usesCleartextTraffic="false"`)**:
  All network traffic is encrypted using standard TLS. Plaintext HTTP connections are unconditionally blocked at the OS network stack.
* **Strict Domain Pinning**:
  The embedded WebKit engine is restricted to official Google domains (`messages.google.com`, `accounts.google.com`, `*.google.com`, `*.gstatic.com`).
* **Safe External Forwarding**:
  If a message contains an external hyperlink, the embedded engine refuses to load it internally and instead dispatches it safely to your device's external web browser, preventing arbitrary code or tracking scripts from entering the sandbox.

---

## 5. Anti-Extraction & Hardware Protections
* **Backup Extraction Disabled (`android:allowBackup="false"`)**:
  The app disables ADB USB backup dumps and cloud migration backups. Attackers cannot clone your pairing keys, active sessions, or message caches via USB or automated cloud backups.
* **Hardware-Backed App Lock**:
  The app features an integrated 4-digit master PIN and Biometric Authentication (Fingerprint & Face Unlock) backed by Android's hardware `BiometricPrompt`.
* **Configurable Auto-Lock**:
  Users can configure the app to re-lock immediately upon backgrounding or after 1 or 5 minutes of inactivity.

---

## 6. Permissions & How They Are Used
Multi-Message Hub requests only the minimal permissions necessary for core functionality:
* `INTERNET` & `ACCESS_NETWORK_STATE`: Required to connect directly to `messages.google.com`.
* `POST_NOTIFICATIONS`: Required to alert you when a new SMS/RCS message arrives.
* `FOREGROUND_SERVICE` & `FOREGROUND_SERVICE_DATA_SYNC`: Required to keep paired web sessions active in the background for real-time message sync.
* `USE_BIOMETRIC`: Required for optional hardware fingerprint and face unlock authentication.
* `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: Optional user-prompted exemption to prevent aggressive OEM battery killers (MIUI, OneUI) from terminating background sync.

---

## 7. Contact & Developer Information
If you have any questions or security feedback regarding this policy or the application architecture:
* **Lead Developer**: MajorThug
* **Application**: Multi-Message Hub
* **Repository**: [Multi-Message Hub on GitHub](https://github.com/Rian445/multi-messenger)

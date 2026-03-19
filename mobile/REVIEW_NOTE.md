# App Store Review Notes — RemoteCode (io.remotecode)

## What is RemoteCode?

RemoteCode is a free, open-source mobile companion for software developers. It connects to the user's own desktop computer running the RemoteCode desktop app, allowing them to monitor and interact with their coding sessions remotely from their phone.

The app does NOT generate code or run AI models on-device. It is a remote client that displays and relays messages between the user and their own development environment.

Source code: https://github.com/remotecode

---

## How to Test the App

### Free Mode (LAN / VPN — No Account Required)

1. Open the app → tap "Add Connection"
2. If a desktop running RemoteCode is on the same Wi-Fi network, the app auto-discovers it
3. Alternatively, enter the desktop server URL manually (e.g., `http://192.168.1.100:8787`)
4. Once connected, the user can view active threads, send messages, and monitor coding sessions

No account, subscription, or payment is needed. The app is fully functional for free when connected via LAN or VPN.

### Private Account Mode (Remote Relay — Optional Subscription)

1. Open the app → scroll to "Private Account" → tap "Register in browser"
2. Create an account at https://remotecode.io/register
3. Log in with email and password
4. If the user has an active subscription, their registered desktop connectors appear under "Your Servers"
5. Tap a connector to connect remotely through our relay infrastructure

---

## Business Model — No In-App Purchase Required

RemoteCode follows the same model as apps like Screens VNC, Termius, and Jump Desktop:

- **The app is free.** All features are available at no cost when the user connects via LAN or VPN to their own computer.
- **The optional subscription pays for cloud relay server infrastructure**, not for app functionality. Users who want to access their desktop from outside their local network subscribe at https://remotecode.io/app to use our relay servers.
- **No digital content is unlocked.** The subscription does not gate any app feature, screen, or capability. It provides access to relay infrastructure (physical servers) that proxy the connection between the mobile device and the user's desktop when they are not on the same network.
- **Subscription management happens on the web** because the payment is for server infrastructure, not digital content delivered through the app.

This model falls under Guideline 3.1.3(a) — the app is a client for the user's own content/service, and the optional payment is for external infrastructure, comparable to a VPS or cloud hosting service.

---

## NSAllowsArbitraryLoads Justification

The app sets `NSAllowsArbitraryLoads: true` because it connects to user-owned servers on their local network. These servers:

- Run on arbitrary LAN IP addresses (e.g., `192.168.x.x`, `10.x.x.x`, `fe80::...`)
- May use HTTP (not HTTPS) since they are on a trusted local network
- Are discovered automatically via local network scanning

The app cannot predict or pre-configure the IP addresses or TLS configuration of the user's own desktop server. This is the same reason apps like SSH clients, remote desktop viewers, and home automation apps require this exception.

All communication with our own backend (`private.remotecode.io`) uses HTTPS.

---

## UIBackgroundModes Justification

- **remote-notification**: Used to wake the app when a push notification arrives (e.g., thread completion notifications via APNS). This is the primary background mode actively used.
- **fetch** and **processing**: Declared by the Expo framework for background task support (ExpoBackgroundTask and ExpoTaskManager modules). These are available for background session refresh but are framework-level declarations.

---

## Live Activities

The app uses Live Activities (iOS 16.2+) to show real-time progress of coding threads on the Lock Screen and Dynamic Island. Updates are delivered via direct APNS push tokens — not through Firebase/FCM. The implementation is in `RemoteCodeLiveActivityBridge.swift`.

---

## Privacy & Data

- **Data collected**: Only email address, for optional account login. No phone number, location, contacts, or tracking data.
- **No analytics or tracking SDKs**: Firebase Analytics is disabled (`IS_ANALYTICS_ENABLED: false`). Firebase is used only for push notification delivery on Android. iOS push notifications use direct APNS.
- **Privacy Manifest**: `PrivacyInfo.xcprivacy` is included and declares all Required Reason APIs used by the app and its dependencies.
- **Privacy Policy**: https://remotecode.io/privacy (accessible in-app)
- **Terms of Use**: https://remotecode.io/terms (accessible in-app)
- **Account deletion**: Fully implemented. Settings → Private Account → Options (⋯) → Delete account, with confirmation dialog.

---

## AI Provider Labels in the UI

The app displays provider names ("Claude Code", "Codex") in the chat interface. These refer to the AI coding agents running on the user's own desktop — the mobile app is simply a remote viewer. The user selects which provider their desktop uses. RemoteCode does not run, host, or resell these AI services. It displays the provider name the same way a terminal app displays the shell name (bash, zsh, etc.).

---

## No Sign in with Apple Required

The app uses only email/password authentication for its optional private account feature. No third-party social logins (Google, Facebook, GitHub) are offered. Per Guideline 4.8, Sign in with Apple is only required when third-party social login options are present.

---

## Local Network Usage

`NSLocalNetworkUsageDescription`: "Remotecode discovers and connects to your local desktop server."

The app scans the local network to find desktop instances of RemoteCode running on the user's computer. This is core functionality — the primary way users connect for free without needing an account.

---

## Summary

| Aspect | Details |
|--------|---------|
| Bundle ID | `io.remotecode` |
| Price | Free |
| IAP | None |
| Subscription | External (server infrastructure only) |
| Account required | No (optional for remote relay) |
| Account deletion | Yes |
| Privacy Policy | https://remotecode.io/privacy |
| Terms of Use | https://remotecode.io/terms |
| Tracking | None |
| Minimum iOS | 15.1 |

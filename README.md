<p align="center"><img src="Design/Logo.png" width="160" alt="PairMagic icon"></p>

<h1 align="center">PairMagic</h1>

<p align="center"><em>Make every accessory magic.</em></p>

Apple's Magic accessories pair the moment you plug them in. PairMagic gives other Bluetooth
accessories that same ease. It's a native macOS menu bar app (Swift, SwiftUI + AppKit, IOBluetooth/CoreBluetooth) that watches for
Bluetooth devices in pairing mode and pops up a one-click **Pair** prompt.

- Detects keyboards, mice, game controllers, headsets and speakers, and shows a matching icon.
- Shows a description built from the device's Bluetooth class, transport and signal strength.
- **Replaces old pairings**: if the same device (same address) is already paired, the stale pairing
  is removed first. With *Replace Paired Devices with the Same Name (Experimental)* on (off by default), a paired device
  with the same name, such as your old controller of the same model, is removed too.
- Handles keyboard passkeys: if a keyboard needs a code, the popup shows it big enough to type.

## Build & run

Open `PairMagic.xcodeproj` in Xcode and press ⌘R, or:

```bash
xcodebuild -project PairMagic.xcodeproj -scheme PairMagic -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/PairMagic.app
```

On first launch macOS asks for Bluetooth permission. Allow it.

The project signs with an Apple Development certificate (set under Signing & Capabilities). A real
signing identity matters here: macOS ties the Accessibility permission to the app's signature, and
an ad hoc signature changes on every rebuild, which silently cancels the permission. If you build
it under a different team, change `DEVELOPMENT_TEAM` there. To use *Launch at Login*, copy the built
app to `/Applications`.

## Releasing

PairMagic is distributed outside the Mac App Store. It needs the Accessibility API and private
Bluetooth APIs, and neither is allowed in the App Sandbox or by App Review.
`scripts/release.sh` builds a DMG that's signed with Developer ID and notarized, so it opens on
any Mac without Gatekeeper warnings.

One-time setup:

1. Create a **Developer ID Application** certificate. In Xcode, go to Settings › Accounts › your team ›
   Manage Certificates › + › Developer ID Application, or create it at developer.apple.com ›
   Certificates.
2. Create an app-specific password at [account.apple.com](https://account.apple.com) and save it
   for notarization:

   ```bash
   xcrun notarytool store-credentials PairMagic-Notary --apple-id <your Apple ID> --team-id B4H429V95D
   ```

For each release, bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in the project, then run:

```bash
scripts/release.sh
```

The script archives a Release build and checks its signature and hardened runtime. It notarizes and
staples the app, packages it with an Applications shortcut, then signs, notarizes and staples the
DMG. The result is `build/release/PairMagic-<version>.dmg`. To test the script without a Developer ID
certificate, run `SIGNING_IDENTITY="Apple Development" SKIP_NOTARIZATION=1 scripts/release.sh`.
The result only opens on your own Mac.

## Icon

The icon is drawn in code by [`Design/RenderIcon.swift`](Design/RenderIcon.swift). To regenerate a
size after changing it, run `swift Design/RenderIcon.swift <output.png> <pixels>`. The app icon set
is in `PairMagic/Assets.xcassets/AppIcon.appiconset`.

## How it works / limitations

- **Bluetooth Classic** (most game controllers, older keyboards and mice, headsets): a continuous
  `IOBluetoothDeviceInquiry` only finds *discoverable* devices, which here means "in pairing mode".
  Pairing uses `IOBluetoothDevicePair`, and the app connects right after so the device works at once.
- **Bluetooth LE** (many newer mice and keyboards): devices that advertise the HID service are offered.
  CoreBluetooth has no public "pair" API, so the app connects and touches the device's protected
  characteristics, which makes macOS pair it. macOS may show its own "Connection Request" alert.
  This route is best-effort. If it times out, use the **Bluetooth Settings…** button.
- **Auto-confirming the macOS prompt**: with *Auto-Confirm macOS Pairing Prompt* on (the default),
  the app uses the Accessibility API to press **Connect** on the system's LE pairing alert. It only
  does this for 30 seconds after you click Pair, and only on an alert that names that device. Any
  other pairing request still needs your approval. The app needs Accessibility permission (System
  Settings › Privacy & Security › Accessibility). The setup window, under *Permissions…* in the menu,
  walks you through it. If the alert isn't recognized, it's
  left for you to click. To see what the app found, run
  `/usr/bin/log stream --predicate 'subsystem == "com.kristenadd.PairMagic"'`.
- **Replacing old pairings**: with *Replace Paired Devices with the Same Name (Experimental)* on (off by default, and turning it on explains how it works), the app removes
  older pairings with the same name once the new pairing works, but only disconnected ones that existed
  before you clicked Pair. Some devices, such as Logitech mice, get a new address on every re-pair. A
  shortened advertised name like "Logi M550" matches the stored "Logi M550 L". *Remove Disconnected
  Duplicates* in the menu does the same cleanup on demand.
- **How pairings are removed**: Apple has no public unpair API. Recent macOS silently ignores the private
  ones (`-[IOBluetoothDevice remove]`, `-[CBPairingAgent unpairPeer:]`) from apps that aren't Apple's.
  The app still tries `remove` first, but then has System Settings do it: through the Accessibility API, it
  opens Settings › Bluetooth, opens **Show Detail** on a "Not Connected" row with that name, and clicks
  **Forget This Device…**. It checks each removal against the paired list, and quits Settings afterwards
  if it opened it. If a macOS update changes that pane, removal fails and the app tells you which entries
  are left. For the same reason, and because it uses private APIs, the app isn't sandboxed and can't go
  on the Mac App Store.
- Scanning pauses while a pairing runs, because an inquiry interferes with pairing.

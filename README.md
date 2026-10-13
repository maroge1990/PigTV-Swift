# PigTV Apple client

The native client for [PigTV](https://github.com/maroge1990/PigTV) (a self-hosted live TV server) on **Apple TV**, **iPad** and
**iPhone**: SwiftUI with a UIKit guide grid and AVFoundation playback. Build **1.0 (40)**, for server build 0207.

What it has: a Home screen (continue watching and shelves), the TV guide (a UIKit grid on Apple TV and iPad, an "On now" list on
iPhone), a Sport tab (events across channels for the next 72 hours, with replays), recordings (scheduling, playback with
break skipping), PigTV's own players (remote-driven on tvOS, large touch controls on iPad/iPhone), a Top Shelf extension, and
deep links. It needs a PigTV server on the local network or VPN.

## Build and run

Requirements: Xcode 27 (deployment targets iOS/tvOS 26.5; tests run on the tvOS 27 simulator); physical devices need development signing, and the App Group
`group.au.markrogers.PigTV` registered for both the `PigTV` and `PigTVTopShelf` targets (Signing & Capabilities).

Open `PigTV.xcodeproj`, choose the shared **PigTV** scheme and an Apple TV, iPad or iPhone destination, and run. From the command
line (on the development Mac `xcode-select` points at the Command Line Tools, so set `DEVELOPER_DIR`):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test  -project PigTV.xcodeproj -scheme PigTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0'
xcodebuild build -project PigTV.xcodeproj -scheme PigTV -destination 'generic/platform=iOS Simulator'
sh Tools/test-contracts.sh    # synthetic API/model checks, no server
```

In the app, enter the server's origin (e.g. `http://192.168.1.235:3000`, no path), then sign in or choose **Pair with browser**
and approve the code in the web app's Settings → Devices. Credentials are kept in the Keychain per server.

Work happens on `main`; pushes run CI (`.github/workflows/ci.yml`: iOS build, tvOS tests).

## Where to read next

| Document | For |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Start here when working on the code: commands, how changes ship, the rules |
| [`blueprint.md`](blueprint.md) | Architecture screen by screen, implementation constraints, crash lessons, known limitations |
| [`TESTING.md`](TESTING.md) | What the suites cover, UI fixtures, measuring on the Apple TV |
| [`../PigTV/docs/CLIENT-CONTRACT.md`](../PigTV/docs/CLIENT-CONTRACT.md) | What the server promises: `/api/info` flags, frozen shapes, contracts C-A…C-K |
| `../PigTV/blueprint.md` §4 | The joint roadmap |
| [`docs/archive/`](docs/archive/README.md) | Frozen history (old handovers, blueprints, test evidence, server requests) |

# PigTV client: testing

Current state and rules: [blueprint.md](blueprint.md). The device checklist is the server repo's
`../PigTV/docs/TEST-BLOCK.md`. The old per-build evidence (builds 3–16) is frozen in
[docs/archive/TESTING-2026-09-23.md](docs/archive/TESTING-2026-09-23.md).

Who tests what: the agent runs builds and simulator tests; Mark runs the physical Apple TV, iPad and iPhone checks. A simulator
pass is not a device pass, and nothing becomes *Verified* until Mark reports it. Ask Mark before contacting the deployed
server or driving the simulator UI by hand.

## Commands

`xcode-select` on the development Mac points at the Command Line Tools, so every command needs `DEVELOPER_DIR`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Before every push: all tests on the tvOS simulator (30 Sept, build 36: 150 pass, 133 unit + 17 UI, ~10 min)
xcodebuild test -project PigTV.xcodeproj -scheme PigTV \
  -destination 'platform=tvOS Simulator,name=Apple TV,OS=26.5'

# When shared code changed: the iOS build
xcodebuild build -project PigTV.xcodeproj -scheme PigTV -destination 'generic/platform=iOS Simulator'

# iPad: the unit tests that aren't tvOS-only
xcodebuild test -project PigTV.xcodeproj -scheme PigTV -only-testing:PigTVTests \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5'

# One suite or test
xcodebuild test -project PigTV.xcodeproj -scheme PigTV \
  -destination 'platform=tvOS Simulator,name=Apple TV,OS=26.5' -only-testing:PigTVTests/RealPlaybackTests

# Synthetic API/model contract checks, no simulator and no server (30 Sept: 204 pass)
sh Tools/test-contracts.sh

# Increment the shipping build number in all four configurations (Debug/Release, app + Top Shelf)
sh Tools/bump-build.sh     # 36 → 37
sh Tools/bump-build.sh 42  # set to 42 (should be run in every commit that changes the app)
```

Simulators by name (Xcode 27): **Apple TV** (tvOS 26.5, the one the tests use), Apple TV 4K (3rd generation) (tvOS 27.0);
**iPad Pro 13-inch (M5)** and the other iPads, iPhone 17 / 17 Pro Max / Air (iOS 26.5; iOS 27.0 variants too). Use names, not
UDIDs: the UDIDs differ per Mac. CI (`.github/workflows/ci.yml`) builds for iOS and runs the tvOS tests on the newest Apple TV
simulator it finds.

The scheme sets `PIGTV_SYNTHETIC_TESTS=1` for the test host, so it never restores a saved real-server session.

## What the suites cover

**Unit tests (`PigTVTests`)**
- `ContractChecks` (via `PigTVTests.swift` and `Tools/test-contracts.sh`): JSON fixtures for every server response the client
  decodes (conflicts, 429, 202 preparing, resolve errors, flags, recordings, HLS recordings, sport events).
- `PlaybackLifecycleTests`: C2 recovery (one automatic attempt), takeover, terminal status, dismissal, the -11868 and `'fmt?'`
  fallbacks, the AVKit-category crash guard.
- **`RealPlaybackTests`, the real-playback harness**: `Support/LocalHTTPServer.swift` (an in-process HTTP server on
  127.0.0.1) and `Support/FakePigTVServer.swift` (resolve, HLS sessions, conflict, client events, sport events) serve the
  `Fixtures/HLS` stream (6 s, H.264 + AAC, fMP4, a master playlist like the server's). Real starts, display criteria, -11868 for
  real, the `'fmt?'` fallback, switching, a recording in the recording player, a sport event's best channel. **New playback
  code gets a test here.**
- `ProviderFailoverTests` (build 36, multi-provider client): C-J provider on resolve and in the stream info line, C-K reminders (once per
  local day, never during playback, hidden without the flag, auto-dismiss), the renewed recovery allowance with an injected clock.
- Pure logic: `GuideGridMathTests`, `GuideModelTests` (indexed lookup, cursor paging; build 33: `extendGuideForward` merges a
  slice and advances `guideLoadedUntil`, ends cleanly when a slice is empty, a failed page is retried before it surfaces,
  `retryGuide` resumes paging rather than restarting, and a 1 000-channel timing check), `ChannelNumberTests`, `OnNowRowTests`,
  `HomeRowsTests`, `DetailTextTests`, `PlayerSharedTests` (touch chrome timer, seek window), `TimeshiftMathTests`,
  `DisplayModeTests`, `StreamInfoTests`, `SportTests` (buckets, days over 72 h, replays, tolerant decoding, the model against
  the fake server; build 33: `playsChannelNow`), `ChannelQueryTests` (Siri matching), `TopShelfTests` and `TopShelfCardTests`
  (snapshot storage, App Group paths, the extension's entry point, card layout and file names, diagnostics).

**UI tests (`PigTVUITests`, tvOS)**
- `PigTVUITests`: Settings appearance switching. `PigTVUITestsLaunchTests`: launch screenshot.
- `GuideGridNavigationUITests`: the UIKit guide's remote navigation, Now/Earlier/Later, long-press menu, focus after details;
  build 33: moving right past 24 h reaches real next-day programmes instead of stalling (`GuideFixtures.forwardHorizon`, 26 h
  of offline fixture data, no server needed).
- `HomeUITests`: Home opens first; Down reaches Watch, then a card.
- `SportUITests`: chips → first card, long press → channel picker, an upcoming event → its page; build 33: an upcoming
  event's secondary channel offers Record/Watch when it starts instead of tuning immediately.
- `TabSwitchUITests`: walks all five tabs twice on 1,000 channels; fails on a stall over 1 s (uses the tab probe).
- `TabFlashUITests`: switches tabs in dark and light, failing if a screenshot is over half the wrong colour (the build 32 flash).
- `BrandSplashUITests`: the branded splash draws (`PIGTV_UI_TEST_SCREEN=splash`). `GuideGridNavigationUITests` also covers Jump to… (opens with focus on the day, Show guide, focus back on the grid).
- `TopShelfCardsUITests`: renders the Top Shelf cards through the real export, then focuses PigTV on the Home Screen.

## Offline fixtures (DEBUG builds only)

Launch environment variables that render a screen with made-up data and no server. The UI tests use them; set them in the
scheme's Run → Arguments to look at a screen by hand. Screenshots in `docs/evidence` come from these, so they show fixture
data, not the real feed.

| Variable | Values |
|---|---|
| `PIGTV_UI_TEST_SCREEN` | `settings` · `guide` · `home` · `home-empty` (first run) · `sport` · `sport-empty` · `topshelf-cards` · `player` · `player-channels` (channel panel open) · `player-tuning` (stays on the tuning card) · `programme` · `programme-later` · `record` · `schedule` · `channel` · `recording` · `search` · `jump` · `unreachable` · `splash` (the branded start-up view) · `onboarding` · `sport-event` · `sport-channels` |
| `PIGTV_UI_TEST_APPEARANCE` | `light` or `dark` (the tvOS simulator has no `simctl ui appearance`) |
| `PIGTV_UI_TEST_CHANNELS` | `<n>`: enlarge the Home and Guide fixtures to n channels (e.g. `1000`, for speed tests) |
| `PIGTV_UI_TEST_MEDIA` | A local movie file the `player` fixture plays |
| `PIGTV_UI_TEST_HOME_SCROLL`, `PIGTV_UI_TEST_SPORT_SCROLL` | A shelf or section title to scroll into view (e.g. `Sport now & next`, `Replays`) |
| `PIGTV_UI_TEST_TABPROBE` | `1`: measure the longest stall after each tab switch (`debug.tabSwitch`) |
| `TEST_RUNNER_PIGTV_SCREENSHOT_DIR` | Passed to `xcodebuild test`: `TopShelfCardsUITests` saves its screenshots there |

`Tools/analyse-tab-flash.py` measures a `simctl io recordVideo` capture frame by frame (how the build 32 flash was found).

## Device checklist

The checklist and results live in **`../PigTV/docs/TEST-BLOCK.md`** (rounds 1–4 with a status summary at the top, and
the next round's checks). For a device run, note the app build (Settings → Version), the server build (`/api/version`), the
device and OS, and for a fault the channel and roughly when; keep provider URLs and tokens out of anything shared. Useful
on-device diagnostics: Settings → Diagnostics (tvOS, the Top Shelf), and Console on the Mac filtered to subsystem
`au.markrogers.PigTV.TopShelf` (the Top Shelf and Siri shortcuts).

Checks that no simulator can settle, still open: an HEVC recording; audio/subtitle track selection; whether AVPlayer stops
fetching while paused (C2 rests on it); Siri on Apple TV (parked); everything behind the server's `PIGTV_TUNER=1`.

# PigTV client: testing

Commands and the rules for running them are in [AGENTS.md](AGENTS.md); the architecture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
This file says what each suite covers, how to put a screen up with fixture data, and how to measure on the Apple TV. Mark's
device rounds and results (complete to build 40) are frozen in `../PigTV/docs/archive/TEST-BLOCK-2026-10-13.md`; the old
per-build evidence (builds 3–16) in [docs/archive/TESTING-2026-09-23.md](docs/archive/TESTING-2026-09-23.md).

Who tests what follows the server's test protocol ([`../PigTV/docs/TESTING.md`](../PigTV/docs/TESTING.md), tiers T1–T5):
Claude runs builds, unit and UI tests and drives the tvOS and iOS simulators (attach, screenshots, input) without asking,
because none of it touches a real provider (T1–T3); Mark runs the physical Apple TV, iPad and iPhone checks (T5). A
simulator pass is not a device pass, and nothing becomes *Verified* until Mark reports it.

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
  Why it exists and how it is built (from the retired blueprint, build 28):
  - **Real-playback harness (build 28, `PigTVTests/RealPlaybackTests.swift`, `PigTVTests/Support/`).** Two crashes reached the TV because no test played a stream through the app's own code. `LocalHTTPServer` is an in-process HTTP/1.1 server (Network.framework `NWListener` on 127.0.0.1, random port; one request per connection, `Range` → 206, every request recorded). `FakePigTVServer` puts a minimal PigTV API on it: `POST playback/resolve` (a configurable decision; by default session `s<n>` → `/api/transcode/s<n>/master.m3u8` with `info.fps = 25/1`), the HLS fixture under `/api/transcode/<session>/…` (a session named `pq…` serves a `VIDEO-RANGE=PQ` master), `GET playback/conflict` → `null`, `client-event`/`conflict/decline`/`DELETE playback/<id>` → success; `client()` returns an `APIClient` with `clientEvents` advertised. The fixture (`PigTVTests/Fixtures/HLS`, ~280 KB, command in `fixture-README.txt`) is 6 s of ffmpeg `testsrc2` + sine, H.264 Main 320×180 25 fps + AAC-LC, three 2 s fMP4 segments, `stream.m3u8`, and `master.m3u8` mirroring the server's `buildMasterPlaylist` (FRAME-RATE, VIDEO-RANGE=SDR). Tests: a real start reaches `ready` within 3 s, AVPlayer `.playing` with `.readyToPlay` and a moving clock, the play-start event (from the `timeControlStatus` KVO observer), release on stop; a decision without fps (background asset criteria); **-11868 for real**: the tvOS simulator refuses the PQ variant, the item-status KVO observer reports it and the model plays the same session's `stream.m3u8` with no new resolve (skips itself if a simulator ever plays PQ); the 'fmt?' fallback (synthetic failure, then a real release, second resolve with `audioEncode: true` and real playback); channel switching releases before the next resolve; a recording (C-E HLS answer, fake markers) plays in `RecordingPlayerModel` and its periodic time observer sees the 1–2 s break. **New playback code gets a harness test.**
- `ChannelWarmerTests` (audit R11, predictive warming): the player's warm policy with a hand-moved clock (off by default, dwell, one in
  flight, cancel on background/real play start, the player's previous-or-next choice, the 60 s refresh); `RealPlaybackTests` warm cases use
  the fake server's `/api/playback/warm` (the player's next channel warms with resolve's body, a zap there adopts it and play-start carries
  `warm`).
- `ProviderFailoverTests` (build 36, multi-provider client): C-J provider on resolve and in the stream info line, C-K reminders (once per
  local day, never during playback, hidden without the flag, auto-dismiss), the renewed recovery allowance with an injected clock.
- Pure logic: `GuideGridMathTests`, `GuideModelTests` (indexed lookup, cursor paging; build 33: `extendGuideForward` merges a
  slice and advances `guideLoadedUntil`, ends cleanly when a slice is empty, a failed page is retried before it surfaces,
  `retryGuide` resumes paging rather than restarting, and a 1 000-channel timing check), `ChannelNumberTests`, `OnNowRowTests`,
  `ObservationTests` (audit R05: a guide page does not publish the recordings/favourites stores and vice versa, `HomeModel` publishes nothing for equal inputs and changes for a same-id status change; it also appends a per-screen publish count to `/tmp/pigtv-observation.txt`), `DetailTextTests`, `PlayerSharedTests` (touch chrome timer, seek window), `PlayerTimeMathTests`,
  `DisplayModeTests`, `StreamInfoTests`, `SportTests.swift` (`SportRowsTests`: text, `playsChannelNow`, tolerant
  decoding; `SportModelTests`: the model against the fake server, `live`/`soon`; `SportsGameTests`: the game labels the front page draws), `TopShelfTests` and `TopShelfCardTests`
  (snapshot storage, App Group paths, the extension's entry point, card layout and file names, diagnostics).

**UI tests (`PigTVUITests`, tvOS).** Two tiers in `Tools/test.sh`: **push** (regression: `GuideGridNavigationUITests`,
`RecordingsUITests`, `TabSwitchUITests`, and any new suite) and **visual** (screenshots and
appearance: `BrandDepthUITests`, `TabFlashUITests`, `BrandSplashUITests`, `TopShelfCardsUITests`, `PigTVUITests`,
`PigTVUITestsLaunchTests`). `BrandDepthUITests`' two player checks need `Tools/generate-brand-review-media.sh` (ffmpeg); the
visual tier runs it when ffmpeg is installed, and they skip otherwise.
CI runs none of the UI tiers (D-49). `Tools/test.sh` tiers: `fast` (build, the contract script once, the unit tests), `push` (fast and
the regression UI tests), `visual` (the screenshot suites), `all` (fast, regression and visual). A pass of `all` on a clean tree
writes the git-ignored marker `.ui-full-passed` (the commit), which `Tools/testflight.sh` requires to equal HEAD, so an upload
runs from the Mac's real clone, not an rsync copy. CI checks out the server's `test/golden`, so `GoldenChecks` runs there.
- `PigTVUITests`: Settings › Appearance switching. `PigTVUITestsLaunchTests`: launch screenshot.
- `GuideGridNavigationUITests`: the UIKit guide's remote navigation, Now/Earlier/Later, long-press menu, focus after details;
  build 33: moving right past 24 h reaches real next-day programmes instead of stalling (`GuideFixtures.forwardHorizon`, 26 h
  of offline fixture data, no server needed).
- `RecordPageUITests` (Apple 114, push tier): the record page on the `record`, `record-sport` and `record-change`
  fixtures (What, When it stops, Record on best first, Change recording's Save changes and Cancel recording with Undo).
  `RecordPageTests` (unit) covers its choices and the requests it sends on a `LocalHTTPServer` (`gameId`; the
  `PUT recordings/scheduled/:id` and its 404/405/409 answers).
- `RecordingsUITests` (push tier; D-44 batch 5, Apple 119–122): the Recordings tab's featured recording, cards and Coming
  up, whose All › opens Scheduled; Scheduled's rules and Needs attention beside Coming up and the clash choice (#12); a
  card opening View recording on the tab's stack; Remove acting at once with the Undo toast (focus on Undo, Select puts
  it back). `RecordingsHomeTests` (unit) covers what the tab, Scheduled and View recording list and say, and the team
  match; `RecordingUndoTests` the held server call (hidden at once, nothing sent on Undo, waits for a change in flight,
  a refused call comes back with its error). `PhoneGuideFilterUITests.testAFailedOnNowMenuActionSaysWhy` (iOS, #219).
- `GuideFastScrollUITests` (build 46): on 300 channels, holding Down then Up leaves focus on a row on screen, not pulled
  back to the starting row (the fast swipe's landing scroll was clamped to a stale planned row).
- `PageHeaderPlacementUITests` (build 46, tvOS and iOS): the header title has the same x, y and height on all four tabs.
- `TouchLayoutUITests` (build 46, iOS only, skips on tvOS): the iPhone Guide's Search is icon-only; the touch player has no
  TV Guide button (needs the review movie from `Tools/generate-brand-review-media.sh`).
- `TabSwitchUITests` (audit R03): walks all five tabs twice on 1,000 channels and the 215-event Sport feed; the tab probe must report for every switch, no switch may stall over `PIGTV_TABSWITCH_BUDGET_MS` (default 500 ms) on both laps (a one-lap spike of a loaded simulator is reported, not failed; 26 Oct), and after each switch Down must move focus into the tab's content.
- `TabFlashUITests`: switches tabs in dark and light, failing if a screenshot is over half the wrong colour (the build 32 flash).
- `BrandRulesTests` (unit): no typed-in colours, system red/yellow, greys, sub-82 % playback panels or literal radii in `PigTV/`
  (allowlist: files of a build under review, each with its reason), and the kit's lockups in the catalog (#190).
- `BrandSplashUITests`: the 1.7 splash (launch pig, then the stacked lockup) draws in light and dark and stays up through a breathing half-cycle (`PIGTV_UI_TEST_SCREEN=splash`, `PIGTV_UI_TEST_APPEARANCE`). `GuideGridNavigationUITests` also covers Jump to… (opens with focus on the day, Show guide, focus back on the grid).
- `SportSettingsUITests` (#200): Settings › Sport shows a suggestion, Hide scores and the followed sports; a sport opens its
  page (leagues, Add a league, Record every game, Follow a team…) and Menu returns.
- `SettingsUITests`, `SignInUITests`, `OfflineUITests` (push tier; D-44 batch 6, Apple 129–133): the Settings menu beside
  its page (the page follows the focus; Diagnostics on the TV), Sign out confirming in its row (Stay signed in focused,
  Menu cancels, Sign out signs out), Settings › Sport's Score delay stepping; Sign in's server step and two tiles (Change,
  Username and password, Menu back); Offline's countdown, Try now focused, and Use a different server opening Sign in at
  the server. Unit: `SettingsMenuTests`, `SettingsSportTests` (Score delay's PUT and 409 on a `URLProtocol`, the logo
  match), `SignInStepTests`, `OfflineRetryTests`.
- `SportPhoneFrontUITests` (Apple 139, iPhone only; the tvOS tiers skip it): the iPhone front page on
  `sport-pages-d43.json`: the carousel, a card per sport with fixture rows, a header opens its page, spoiler-free draws no
  score. Run it on the iPhone 17 simulator (`-only-testing:PigTVUITests/SportPhoneFrontUITests`).
  Since Apple 142 it also opens a sport's page (the league's carousel and rows, its rounds and standings on a page of
  their own) and, on the iPad Pro 13-inch simulator, checks that portrait stacks the AFL standings inside the page
  (`testAnIPadInPortraitStacksTheStandingsInsideThePage`). `SportPhonePageTests` (unit): the iPhone sport page's chips,
  carousel, groups, spoiler-free and league-page headers.
- `SportBannerUITests` (D-43, build 97; `front` on `sport-front-0427.json`, times moved to the clock): no tiles, the
  banner's list scrolls in place, a rail header opens a sport page whose banner lists its leagues and flips the content,
  Menu restores focus, a one-league sport is full width, the quiet and nothing-in-72-hours banners.
- `TopShelfCardsUITests`: renders the Top Shelf cards through the real export, then focuses PigTV on the Home Screen.

## Offline fixtures (DEBUG builds only)

Launch environment variables that render a screen with made-up data and no server. The UI tests use them; set them in the
scheme's Run → Arguments to look at a screen by hand. Screenshots in `docs/evidence` come from these, so they show fixture
data, not the real feed.

| Variable | Values |
|---|---|
| `PIGTV_UI_TEST_SCREEN` | `settings` · `settings-sport` (Settings › Sport, C-U) · `guide` · `home` · `topshelf-cards` · `player` · `player-channels` (channel panel open) · `player-tuning` (stays on the tuning card) · `programme` · `programme-later` · `record` · `schedule` · `channel` · `recording` · `recording-game` (a game's View recording) · `recordings` · `search` · `jump` · `unreachable` · `splash` (the branded start-up view) · `onboarding` (Sign in's tiles) · `signin-server` (its server step) · `pairing` · `sport-event` · `sport-channels` |
| `PIGTV_UI_TEST_APPEARANCE` | `light` or `dark` (the tvOS simulator has no `simctl ui appearance`) |
| `PIGTV_UI_TEST_CHANNELS` | `<n>`: enlarge the library and Guide fixtures to n channels (e.g. `1000`, for speed tests) |
| `PIGTV_UI_TEST_MEDIA` | A local movie file the `player` fixture plays |
| `PIGTV_UI_TEST_RECORDINGS_SECTION` | `scheduled`: Recordings opens with Scheduled pushed |
| `PIGTV_UI_TEST_SETTINGS_PAGE` | `sport` · `account` · `appearance` · `labs` · `diagnostics` · `about`: the Settings page shown beside the menu (with `settings` or `settings-sport`) |
| `PIGTV_UI_TEST_FRONT_JSON` | The Sport front page's answer, base64 (with `front`, `home` or `tab-*`); without it `home` and `tab-*` read `PigTVTests/Fixtures/sport-front-0381.json` from the source tree |
| `PIGTV_UI_TEST_DASHBOARD_PLAY` | `1` (with `home` or `tab-*`): a play reaches the real player, which stays tuning (TEST-NET resolve; `OutsidePlayUITests`) |
| `PIGTV_UI_TEST_CLASH` | `1`: the Recordings fixture adds two schedules that clash; one loses (`beatenBy`) and offers "Record this one instead" (#12) |
| `PIGTV_UI_TEST_FRONT_F1` | `1` (with `front`): the Motorsport page embeds the F1 fixture's weekend |
| `PIGTV_UI_TEST_TABPROBE` | `1`: measure the longest stall after each tab switch (`debug.tabSwitch`) |
| `TEST_RUNNER_PIGTV_SCREENSHOT_DIR` | Passed to `xcodebuild test`: `TopShelfCardsUITests` saves its screenshots there |

`Tools/analyse-tab-flash.py` measures a `simctl io recordVideo` capture frame by frame (how the build 32 flash was found).

## Device checks

What to note for a device run, and on-device diagnostics, are in the server's
[`docs/TESTING.md`](../PigTV/docs/TESTING.md) › T5: device checks. Checks no simulator can settle carry the
`needs-device-test` label in the issues (label `apple`).

## Measuring on the Apple TV

The simulator cannot say how the tabs and playback feel; the device can. Audit R03 added signposts (`PigTV/PigTVSignpost.swift`,
subsystem = the bundle id, category **Responsiveness**) so Instruments shows each stage.
- **Measurement (R03).** `PigTVSignpost` (subsystem = bundle id, category "Responsiveness"): `TabSwitch`, `TabFirstFrame`,
  `GuideLoad`/`GuidePage`/`GuideExtend`, `SportLoad`, `HomeRebuild`, `RecordingsLoad`, `Live*` and
  `Recording*` playback stages, `LogoDecoded`. Device profiling: `TESTING.md` → "Measuring on the Apple TV".

1. Build **Release** to the Apple TV from Xcode (Product → Profile, or Run with the Release configuration).
2. Instruments: a blank template with **Time Profiler**, **Hangs**, **os_signpost** (filter the category to Responsiveness) and
   **SwiftUI**. Record, then do: 100 switches Home ↔ Guide ↔ Sport (alternate Right/Left on the tab bar), one live channel play,
   one recording play.
3. Read off:
   - `TabSwitch` (tab-bar selection → the new tab's first content; the end label names it), `TabFirstFrame` (→ its first frame;
     focus stays in the bar during a switch, so this stands in for "focus ready"). Target: p95 under 250 ms.
   - Model work behind them: `GuideLoad`, `GuidePage`, `GuideExtend`, `SportLoad`, `HomeRebuild`, `RecordingsLoad`
     (a long one on the main thread is the stall).
   - Live play: events `LiveResolveRequest` → `LiveResolveResponse` → `LiveItemCreated` → `LiveReadyToPlay` → `LivePlaying`;
     recording: `RecordingPlaybackRequest` → `RecordingItemCreated` → `RecordingReadyToPlay` → `RecordingPlaying`. The gaps between
     them say whether the wait is the server, the player or the app.
   - `LogoDecoded` (artwork, the file name only), and **Hangs** over 100 ms (the main-thread call tree in Time Profiler for the same
     time range names the culprit).
   Signposts carry only fixed names, tab names and a logo file name, never tokens, URLs or provider names.

Stricter tab test on the simulator (the budget defaults to 500 ms because simulators on a busy Mac are noisy; the device target is 250 ms):

```sh
PIGTV_TABSWITCH_BUDGET_MS=250 xcodebuild test -project PigTV.xcodeproj -scheme PigTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' -only-testing:PigTVUITests/TabSwitchUITests
```

(If the variable does not reach the test runner on your Xcode, set `TEST_RUNNER_PIGTV_TABSWITCH_BUDGET_MS=250` instead.)


The recording harness waits for both AVPlayer's raw playing/ready state and RecordingPlayerModel's published
`hasPlayed` before asserting playback. KVO publishes through a MainActor hop, so raw engine state is not proof that
the model callback has run. Keep the existing bounded deadline and periodic-break/timeline/error/release assertions;
CI 40862302742 is the captured failing-before evidence for this test-ordering race.

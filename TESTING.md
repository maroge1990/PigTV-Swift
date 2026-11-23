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
- `MinimumServerTests`: a server below build 0476 is refused with its own text (and on Sign in's Continue); 0476, newer
  and an unparsed build are accepted (D-53).
- `PlaybackLifecycleTests`: C2 recovery (one automatic attempt), takeover, terminal status, dismissal, the -11868 and `'fmt?'`
  fallbacks, the AVKit-category crash guard.
- **`RealPlaybackTests`, the real-playback harness**: `Support/LocalHTTPServer.swift` (an in-process HTTP server on
  127.0.0.1) and `Support/FakePigTVServer.swift` (resolve, HLS sessions, conflict, client events, sport events) serve the
  `Fixtures/HLS` stream (6 s, H.264 + AAC, fMP4, a master playlist like the server's). Real starts, display criteria, -11868 for
  real, the `'fmt?'` fallback, switching, a recording in the recording player, a sport event's best channel. **New playback
  code gets a test here.**
  Why it exists and how it is built (from the retired blueprint, build 28):
  - **Real-playback harness (build 28, `PigTVTests/RealPlaybackTests.swift`, `PigTVTests/Support/`).** Two crashes reached the TV because no test played a stream through the app's own code. `LocalHTTPServer` is an in-process HTTP/1.1 server (Network.framework `NWListener` on 127.0.0.1, random port; one request per connection, `Range` → 206, every request recorded). `FakePigTVServer` puts a minimal PigTV API on it: `POST playback/resolve` (a configurable decision; by default session `s<n>` → `/api/transcode/s<n>/master.m3u8` with `info.fps = 25/1`), the HLS fixture under `/api/transcode/<session>/…` (a session named `pq…` serves a `VIDEO-RANGE=PQ` master), `GET playback/conflict` → `null`, `client-event`/`conflict/decline`/`DELETE playback/<id>` → success; `client()` returns an `APIClient` with `clientEvents` advertised. The fixture (`PigTVTests/Fixtures/HLS`, ~280 KB, command in `fixture-README.txt`) is 6 s of ffmpeg `testsrc2` + sine, H.264 Main 320×180 25 fps + AAC-LC, three 2 s fMP4 segments, `stream.m3u8`, and `master.m3u8` mirroring the server's `buildMasterPlaylist` (FRAME-RATE, VIDEO-RANGE=SDR). Tests: a real start reaches `ready` within 3 s, AVPlayer `.playing` with `.readyToPlay` and a moving clock, the play-start event (from the `timeControlStatus` KVO observer), release on stop; a decision without fps (background asset criteria); **-11868 for real**: the tvOS simulator refuses the PQ variant, the item-status KVO observer reports it and the model plays the same session's `stream.m3u8` with no new resolve (skips itself if a simulator ever plays PQ); the 'fmt?' fallback (synthetic failure, then a real release, second resolve with `audioEncode: true` and real playback); channel switching releases before the next resolve; a recording (C-E HLS answer, fake markers) plays in `RecordingPlayerModel` and its periodic time observer sees the 1–2 s break. **New playback code gets a harness test.**
- `GuideFirstPageTests` (maroge1990/PigTV#360, #361): a launch with no usable saved guide asks first for 50 channels and 6 hours,
  shows them, then loads the full guide exactly as before (the same end state, cache and version); the small page is never saved
  and never outlives a failed load.
- `GuideRefreshSwapTests` (maroge1990/PigTV#360, G6): a stale-guide refresh keeps every row on screen until the whole new guide
  has arrived, then swaps it in with one change of `guide`; a failed refresh page leaves the old guide whole and Try again
  finishes the swap.
- `GuideExtendOffMainTests` (maroge1990/PigTV#360, G7): a forward extension's merge and trim run off the main actor and equal the old
  main-actor merge on the 1,250-channel fixture (duplicate starts, the 24 h trim); a sign-out during the merge wins.
- `GuideLoadReviewTests` (Codex review of Apple 383-385): a staged refresh changes the day, its loaded edge, the version and the
  rows together (a failed one leaves them all, and the next pass loads); a freshness pass joins a staged refresh still paging and
  resumes one stopped on a failed page from its cursor; of two overlapping resets only the newest proceeds, with its own version;
  the Top Shelf snapshot is never built from the small first page.
- `GuideQuietTests` (maroge1990/PigTV#360): the Guide's quiet paths on the real views in a window: a focus move does not
  re-evaluate `GuideView.body` (only the focus strip observes the focus); the 30 s clock tick reconfigures only the grid
  cells whose drawing changed (on air: the progress bar; a roll-over), not every visible cell; a long-press menu left open
  past its programme's end loses its RECORD items at the next tick; a page of channels appended below the screen configures
  no cell on screen again and asks the layout for at most 500 items (one per item of every new row before Apple 388). No grid cell
  is sized to fit by UIKit (`preferredLayoutAttributesFitting` returns the layout's attributes; Apple 390). `ChannelArtworkTests`: a logo in memory draws on the
  first frame and stays drawn if the cache evicts it; fetches stop when no view waits; a stale end of display (on a
  reload) leaves a visible Guide tile loading its logo.
- `ChannelWarmerTests` (audit R11, predictive warming): the player's warm policy with a hand-moved clock (off by default, dwell, one in
  flight, cancel on background/real play start, the player's previous-or-next choice, the 60 s refresh); `RealPlaybackTests` warm cases use
  the fake server's `/api/playback/warm` (the player's next channel warms with resolve's body, a zap there adopts it and play-start carries
  `warm`).
- `ProviderFailoverTests` (build 36, multi-provider client): C-J provider on resolve and in the stream info line, C-K reminders (once per
  local day, never during playback, auto-dismiss), the renewed recovery allowance with an injected clock.
- Pure logic: `GuideGridMathTests`, `GuideModelTests` (indexed lookup, cursor paging; build 33: `extendGuideForward` merges a
  slice and advances `guideLoadedUntil`, ends cleanly when a slice is empty, a failed page is retried before it surfaces,
  `retryGuide` resumes paging rather than restarting, and a 1 000-channel timing check), `ChannelNumberTests`, `OnNowRowTests`,
  `ObservationTests` (audit R05: a guide page changes nothing in the recordings/favourites stores and vice versa, a quiet refresh that finds nothing new changes nothing; counted by `Support/Invalidations.swift`, which sees an ObservableObject's publishes and an `@Observable` model's changes to what a view reads alike; it also appends a per-screen count to `/tmp/pigtv-observation.txt`), `StoreObservationTests` (#51: a view reading one store property is not re-evaluated by another), `DetailTextTests`, `PlayerSharedTests` (touch chrome timer, seek window), `PlayerButtonsTests` (#58 option B: which buttons each player
  shows in its row and on its bar, the Apple TV remote's two lines (`PlayerCursor`), #308's Start over lookup, #369's equal-width
  row with every name drawn; Apple 407: a bar button going returns the remote to the row, Start over asked again under the
  player, a held control keeps the touch controls), `StartOverHandoffTests` (Apple 407, fake server with a slow release: a
  newer channel or the background during the release wins, a second press does nothing), `PlayerTimeMathTests`,
  `DisplayModeTests`, `StreamInfoTests`, `SportTests.swift` (`SportRowsTests`: text, `playsChannelNow`, tolerant
  decoding; `SportModelTests`: the model against the fake server, `live`/`soon`; `SportsGameTests`: the game labels the front page draws), `TopShelfTests` and `TopShelfCardTests`
  (snapshot storage, App Group paths, the extension's entry point, card layout and file names, diagnostics).

**UI tests (`PigTVUITests`, tvOS).** Two tiers in `Tools/test.sh`: **push** (regression: `GuideGridNavigationUITests`,
`RecordingsUITests`, `TabSwitchUITests`, and any new suite) and **visual** (screenshots and
appearance: `BrandDepthUITests`, `TabFlashUITests`, `BrandSplashUITests`, `TopShelfCardsUITests`, `PigTVUITests`,
`PigTVUITestsLaunchTests`). `BrandDepthUITests`' two player checks need `Tools/generate-brand-review-media.sh` (ffmpeg); the
visual tier runs it when ffmpeg is installed, and they skip otherwise.
The MacBook is the test gate (D-77): `sh Tools/mac-gate.sh <tier> [--worktree]` runs `Tools/test.sh <tier>` there. GitHub CI is
non-blocking and not watched, and runs none of the UI tiers (D-49). Tiers: `fast` (build, the contract script once, the unit
tests), `push` (fast and the regression UI tests), `visual` (the screenshot suites), `all` (fast, regression and visual),
`perf` (only the speed suites, below; in no other tier), `profile` (#360 E1: Time Profiler attached through the simulator to the
app while `GuidePerfUITests.testProfileScenarios` presses down 40, up 40 and right 10; `Tools/profile-summary.py` prints the main
thread's on-CPU ms per press by phase, top-of-stack symbol and nearest app frame, and the samples as `PROFILE-DATA` base64 for
summarising again off the Mac (`python3 Tools/profile-summary.py samples.json.gz - 40,40,10`); the trace is deleted; in no other
tier; the figures include the XCUITest accessibility queries and Debug-only work), `ios` (#53: the unit tests, and `TouchPlayerButtonsUITests`, on one iPad simulator, then one iPhone
simulator, one at a time; in no other tier; `PIGTV_IPAD_SIM` / `PIGTV_IPHONE_SIM` name the devices). TestFlight builds come only
from Xcode Cloud `tf/` tags (D-64); `Tools/testflight.sh` is retired and the `.ui-full-passed` marker a clean `all` still writes
is only a record. Both CI and the Mac check out the server's `test/golden`, so `GoldenChecks` runs.

**Test plans and Xcode Cloud (#351).** The scheme has two test plans. `PigTV.xctestplan` skips nothing; `Tools/test.sh` names it (`-testPlan PigTV`), and in Xcode choose it with Product › Test Plan. `XcodeCloud.xctestplan` is the scheme's
default because the release workflow's Test actions can only "Use scheme settings" (Xcode 27): Xcode Cloud builds on one
machine and runs `test-without-building` on another that has only the build products, so it leaves out the static source scans
(`BrandRulesTests`, `HelperLinesGoneTests`, `SelectionFlatTests`, `SportHideScoresWriterTests`, `LaunchImageTests`,
`TestPlanTests`, two `PolishTests` colour-catalogue reads, two `SportSpoilersTests` source scans), which run on the Mac, and four timing probes that failed on its runners (`TabSwitchUITests`' thousand-channel switch, `OutsidePlayUITests`,
`TouchLayoutUITests`' Watch on menu, `PlayerSlowStartUITests`' fixed 4.5 s wait) and the Guide's speed suite (`GuidePerfUITests`). `TestPlanTests` pins both lists. What tests read ships in their bundles: the JSON fixtures
are also members of `PigTVUITests` (read through `UIFixture`), the Debug app carries `sport-front-0381.json` for the offline
Home (Release excludes it), and the PigTVTests "Golden answers" build phase copies `../PigTV/test/golden` (or
`PIGTV_GOLDEN_DIR`) into the bundle as `golden/` (`ci_scripts/ci_post_clone.sh` fetches it on Xcode Cloud's build machine).
To check a change against the cloud runner: build for testing, copy `Build/Products` elsewhere, move the source tree away, and run
`xcodebuild test-without-building -xctestrun Products/PigTV_XcodeCloud_<platform>.xctestrun`.
- `PigTVUITests`: Settings › Appearance switching. `PigTVUITestsLaunchTests`: launch screenshot.
- `GuideGridNavigationUITests`: the UIKit guide's remote navigation, Now/Earlier/Later, long-press menu, focus after details;
  build 33: moving right past 24 h reaches real next-day programmes instead of stalling (`GuideFixtures.forwardHorizon`, 26 h
  of offline fixture data, no server needed).
- `RecordPageUITests` (Apple 114, push tier): the record page on the `record`, `record-sport` and `record-change`
  fixtures (#358: What, the Channel page best first, Extra time's left/right steppers, Set to record's Done and Cancel
  recording with Undo); `TouchLayoutUITests` draws each page on iPhone and iPad. `RecordPageTests` and `RecordSheetTests`
  (unit) cover its choices (Extra time's words, usual values and bounds) and the requests it sends on a `LocalHTTPServer` (`gameId`; the
  `PUT recordings/scheduled/:id` and its 404/405/409 answers). #347: `SportPageCardTests` (sport page items' `card`,
  Cancelling… and the lost-cancel reconciliation against a local server, binding by channel identity, a name-only row only
  once the guide has loaded), `CardSlotsCancellingTests` (`slots`, `recordingCancelling`, `guideEnd`, the bound airing),
  `ScheduleReadAfterWriteTests` and `ScheduleTicketsTests` (the scheduled list's reads after a write and their order).
- `RecordingsUITests` (push tier; D-44 batch 5, Apple 119–122): the Recordings tab's featured recording, cards and Coming
  up, whose All › opens Scheduled; Scheduled's rules and Needs attention beside Coming up and the clash choice (#12); a
  card opening View recording on the tab's stack; Remove acting at once with the Undo toast (focus on Undo, Select puts
  it back). `RecordingsHomeTests` (unit) covers what the tab, Scheduled and View recording list and say, and the team
  match; `RecordingUndoTests` the held server call (hidden at once, nothing sent on Undo, waits for a change in flight,
  a refused call comes back with its error). `PhoneGuideFilterUITests.testAFailedOnNowMenuActionSaysWhy` (iOS, #219).
- `GuideHeadingsUITests` (push tier, #372): on the headings fixture (`PIGTV_UI_TEST_GUIDE_SHAPE=headings`: a heading first, one
  beside the channel with no programmes, two in a row, one last) Up and Down pass over every heading and Left/Right stay in the
  row. `GuideHeadingRuleTests` (unit) covers the rule (near-misses, other scripts), the row geometry and the store;
  `GuideHeadingTests` the grid's bands on the real controller, a guide without headings laid out exactly as before, a row
  turning into a heading without moving the screen, and the consumers that leave headings out. `GuideScreensUITests.
  testGuideWithHeadings` shoots the fixture (visual tier).
- `PlayerButtonsUITests` (push tier, #58/#308, needs the review movie): on the live player the chrome opens on Pause, Down
  reaches Go to live then Start over on the bar, Up returns, and Start over ends the live play (fixture
  `PIGTV_UI_TEST_START_OVER=1`); on a recording still being made a break selects Skip break on the bar, Go to live follows it,
  and Down from the bar hides. `TouchPlayerButtonsUITests` (`ios` tier, iPad and iPhone, Apple 407): Skip break and Go to
  live at the scrub bar's end, Auto-skip breaks flips, Start over and Go to live on the live bar, and Skip break held past
  the idle deadline still skips.
- `GuideFastScrollUITests` (build 46): on 300 channels, holding Down then Up leaves focus on a row on screen, not pulled
  back to the starting row (the fast swipe's landing scroll was clamped to a stale planned row).
- `PageHeaderPlacementUITests` (build 46, tvOS and iOS): the header title has the same x, y and height on all four tabs.
- `TouchLayoutUITests` (build 46, iOS only, skips on tvOS): the iPhone Guide's Search is icon-only; the touch player has no
  TV Guide button (needs the review movie from `Tools/generate-brand-review-media.sh`).
- `TabSwitchUITests` (audit R03): walks all five tabs twice on 1,000 channels and the 215-event Sport feed; the tab probe must report for every switch, no switch may stall over `PIGTV_TABSWITCH_BUDGET_MS` (default 500 ms) on both laps (a one-lap spike of a loaded simulator is reported, not failed; 26 Oct), and after each switch Down must move focus into the tab's content.
- **`GuidePerfUITests` (#362, `perf` tier only: `sh Tools/mac-gate.sh perf`)**: the Guide's responsiveness on the production-shaped
  fixture (1,250 channels, a day of programmes with 150–300-character descriptions, a logo each through the real artwork path, 40
  categories). (a) first screen, (b) 40 single presses down at about 3 a second, each waiting for its move to land, (c) 40 up,
  (d) 10 right, (e) a held scroll of about 100 rows, (f) 35 s idle (the 30 s clock tick), (g) 45 presses down from the moment
  the first page's rows show while pages 2–3 arrive (7 s apart; the window starts after the move that entered the grid; fewer than 2 applies in it fails as a test-setup fault); (b) again under `measure(metrics:)` with `XCTOSSignpostMetric` (GuideFocusMove). `testGuideLoadingFigures` prints one `GUIDE-LOAD {…}` line of figures the app measures on the fixture
  (PIGTV_UI_TEST_GUIDE_FIGURES=1, `ProductionGuideFigures`): `secondGuideMB`, the heap a second whole guide takes (a refresh holds
  two at its swap), and `mergeMs`, a forward extension's merge and trim on it (off the main actor since Apple 385).
  A signpost interval can only end at the frame callback, up to a frame before the probe's frame-due time, so Xcode's
  GuideFocusMove figure is callback timing: each of its runs prints the probe's figures for the same presses
  (`GUIDE-SIGNPOST run n: …`), and each completed GuideFocusMove/GuideFirstScreen signpost's end message carries the
  frame-due figure (`frameDueMs`). Compare the probe's figures, never Xcode's, with the GUIDE-SCROLL lines. Each scenario prints and
  attaches one line `GUIDE-SCROLL {"scenario":…, <probe JSON>}`: `focusMs` (each move: the grid's focus update → the frame after
  the Guide finished its work, i.e. the display-link callback after the first one following GuideView's handling, timed to when
  that frame is due on screen: a close estimate of what you see, not a camera measurement) with median/p95/max, `pressMs` (an
  arrow press under 1 s before the move → that frame), `maxGapMs`, `gapsOver50`/`gapsOver100`
  and `frames` (a display-link monitor: a main-thread stall shows here whatever the moves say), `bodyEvals`, `cellConfigs`, `layoutPrepares` (full
  grid layout passes; a vertical scroll step that only moves the now line is not one), `logoFetches`/`logoCancels` (channel logo
  fetches started, and cancelled because no tile waited any more), `logoSyncHits`/`logoLateHits` (logos drawn from memory on
  the tile's first frame, or found only by the view's task, a frame late),
  `applies`, `applyMs` (and per press: per focus move that landed), `applyLog` (#360, Apple 388: each apply's path, its own ms
  split into `checkMs`/`updateMs`/`refreshMs`, the per-item layout queries, item counts and list orderings inside it, the layout
  and cell configurations after it up to the next frame and that frame's gap, and whether a move was in flight: an arrow
  down, a press not yet taken by a move, `pressPendingMs`, or a focus move not yet drawn), `appliesInMove`, `itemQueries`/`itemQueryMs`
  (the layout's `layoutAttributesForItem(at:)`), `countQueries`/`countMs` (item counts), `orders`/`orderMs` (programme lists ordered
  on the main thread), `pressHeldMs`/`moveAfterDownMs`/`moveAfterUpMs`/`movesWhileDown` (an arrow press down → up, and → its
  focus move: XCUIRemote's press is up after 5 ms; the focus engine moves focus while UIKit dispatches the press down, about 13 ms
  after it on the simulator, before the press reaches the grid's `pressesBegan`, so the probe pairs a press with the move that
  began during its dispatch; before that fix every move took the previous press, and the 340 ms once reported here was the
  test's press spacing), `cellConfigMs`/`cellConfigUs`
  (time inside cell configurations, total and per configuration; the SwiftUI content's own layout comes later in the frame and is
  not in it) and `mainBusyMs` (the main run loop's busy time, frame commits included), `presses` (sent), `focusMoves` (focus events that
  landed), `landedPresses` (presses whose move landed, at most one each, each counted from just before its press),
  `layoutPrepareRuns`/`layoutQueries`/`layoutMs` (the grid layout's `prepare()` and `layoutAttributesForElements(in:)` calls
  and the main-thread ms in both), `dayChanges` (the header's day changed: one body evaluation each), `focusRow` (the focused row's index; the held
  scroll adds `rowsMoved`, its change), `rowsStart`/`rowsEnd`,
  `firstScreenMs` (the Guide's first appearance since launch → the frame after its first rows were configured, timed the same
  way; none if it leaves the screen or has no rows within 30 s), `firstPageBytes` (the first guide page put on screen, its body as
  received; only the paged first screen fetches one, and it must be at most 300 KB: the small first page, Apple 383). A single-press scenario fails unless at least 90 % of its
  presses landed (`landedPresses`, not focus events), the held scroll unless the focused row moved at least 50 rows down
  (`rowsMoved`); budgets apply only after that. Count budgets a fix has earned apply by default (#360: body evaluations per press 0.05 in the up/down scenarios, and in the sideways one no more than the day changes it
  crossed, 0 body evaluations and 0 cell configurations at the idle tick, whose grid shows later programmes; 5 layout element queries per up/down press outside the paged scenario, 19.8 with the layout before Apple 378 and 2.6
  after (`PIGTV_GUIDEPERF_OLD_LAYOUT=1` runs the old layout in the same build, with `_LAYOUT_PER_VERTICAL_PRESS` set high); 0 logos drawn a frame late in the up/down and held scenarios, 36 and 199 before Apple 379); the rest record only unless set: `PIGTV_GUIDEPERF_FOCUS_MS`,
  `_GAP_MS`, `_FIRST_MS`, `_BODY_PER_PRESS`, `_CELLS_PER_VERTICAL_PRESS`, `_LAYOUT_PER_VERTICAL_PRESS`, `_LOGO_LATE`, `_CELLS_AT_TICK`, `_BODY_AT_TICK`, `_APPLY_MS`, `_ITEM_QUERIES` (per-item layout queries in the paged scenario; earned default 1,000, 38,628 before Apple 388) (`Tools/test.sh` and
  `Tools/mac-gate.sh` pass them to the test runner). Each perf run keeps its result bundle and full output in its own
  `build/perf-<UTC time>/` (printed; `Tools/mac-gate.sh perf` copies the output back next to its log from that exact folder, and if the copy fails it
  says so and leaves the output on the Mac, in `~/pigtv-build/perf-kept/`, with its path). The perf tier also prints the Mac's model, CPUs, memory, load and the booted simulator: the figures
  are the MacBook simulator's, never the Apple TV's.
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
| `PIGTV_UI_TEST_GUIDE_SHAPE` | `production` (with `guide`): the speed tests' guide, 1,250 channels unless `PIGTV_UI_TEST_CHANNELS` says otherwise, served by an in-app fake server (`ProductionGuideServer`) through the app's own client |
| `PIGTV_UI_TEST_GUIDE_PAGED` | `1` (with `production`): the guide arrives through the app's own paging, 3 pages of 500 |
| `PIGTV_UI_TEST_GUIDE_PAGE_DELAY_MS` | The fake server's delay before each guide page after the first (default 1000; the paged test uses 7000) |
| `PIGTV_UI_TEST_GUIDEPROBE` | `1`: the Guide's probe (`debug.guidePerf`, JSON; reset by the Darwin notification `au.markrogers.PigTV.guideProbe.reset`) |
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
  `GuideLoad`/`GuidePage`/`GuideExtend`, #362's `GuideApplyRows`, `GuideCellConfigure`, `GuideFocusMove`, `GuideBodyEval`
  (event), `GuideFirstScreen` (`PigTV/GuidePerf.swift`), `SportLoad`, `HomeRebuild`, `RecordingsLoad`, `Live*` and
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
   - `LogoDecoded` (artwork, no metadata), and **Hangs** over 100 ms (the main-thread call tree in Time Profiler for the same
     time range names the culprit).
   Signposts carry only fixed names and tab names, never tokens, URLs or provider names.

**Guide speed readout (#362, no Mac needed).** Settings › About › Guide speed readout (off by default; leave it off otherwise).
Turn it on, use the TV Guide, then come back to About: moves (focus moves in the Guide), typical/slowest (ms from the remote
press to the frame after the Guide finished its work: a close estimate of what you see, not a camera measurement; the footnote
under the line says so), slow frames (gaps over 100 ms while the Guide was on screen), longest stall, first
screen (opening the Guide after launch → the frame after its rows; only when the readout was already on at launch) and the Apple build. Reset starts a new count; note the line with what you felt.

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

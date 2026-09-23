# PigTV Apple client: blueprint

**Last updated:** 23 September 2026 · app **1.0 (16)** · server build 0104

Read this at the start of every session, **together with the joint roadmap in
[`../PigTV/blueprint.md`](../PigTV/blueprint.md) §6**, which is where A-items (Apple) and X-items (both products) are
tracked. This file holds the client's durable facts and rules. It replaced the earlier blueprint on 23 September 2026 after an
independent review; the full U01–U11 and R01–R20 history is frozen in `docs/archive/blueprint-2026-09-23.md`.

## 1. Working rules

- **Push-to-main (Mark, 23 Sept).** Work on `main` in this folder. Claude may `git pull --rebase` and **push to `origin/main`**
  without asking each time. Before every push: the tvOS build and tests pass, plus an iOS build when shared code changed:
  ```bash
  xcodebuild test -project PigTV.xcodeproj -scheme PigTV -destination 'platform=tvOS Simulator,name=Apple TV'
  xcodebuild build -project PigTV.xcodeproj -scheme PigTV -destination 'generic/platform=iOS Simulator'
  ```
  Never force-push. `.gitignore` keeps Xcode and Finder user state out of commits.
- **Bump the build number** (`CURRENT_PROJECT_VERSION`, both app targets in `project.pbxproj`) once per session that changes
  app code, so Settings → Version identifies the installed copy.
- **Organisation:** the lead Claude session delegates implementation to sub-agents and reviews every diff before it's pushed.
  Device-dependent items end with numbered test steps for Mark and become *Verified* only on his report.
- Other internet use still needs Mark's approval: browsing, SDK or dependency downloads, and **contacting the deployed server**.
  Driving the simulator UI (attach, screenshots, input) only when Mark asks in that message; routine checks are `xcodebuild` runs.
- Never send `force: true` automatically: viewer or recording takeover needs an explicit choice. Browsing and focus must never
  acquire a provider stream. Preserve same-origin auth, media URL allow-listing, capability negotiation and release-before-switch.
- Server changes are made in the server repo under its blueprint §2; client-visible server changes appear in
  `../PigTV/docs/SWIFT-CLIENT-HANDOFF.md` §5, so read it at each session start.

## 2. Orientation

| Item | Reference |
|---|---|
| Project | `PigTV.xcodeproj`, shared scheme `PigTV`; iOS/tvOS 26.5 targets; Xcode 27 |
| Baseline (23 Sept) | 22 tests pass on the tvOS simulator (lifecycle, contract runner, guide model, guide navigation and appearance UI tests) |
| Contract runner | `sh Tools/test-contracts.sh` (synthetic, no server) |
| Regression and device procedure | [TESTING.md](TESTING.md) |
| Server requests | [docs/SERVER-REQUESTS.md](docs/SERVER-REQUESTS.md) |

## 3. Device verification state (Mark's reports)

**Accepted on device:** U02 two-device takeover; R07/R08 custom player and side channel list; R17 scrub bar; R18 no hang on
fast category switching; R01–R06 no regressions; AVKit live fallback removed (build 13).
**Awaiting a device check:** R19 swipe-right through the day (build 16) · R14 continuous slide and R16 spacing · R20 light mode
after leaving the player · R13 HDR panel switch on Sky Sports Main Event UHD (client build 14 + server 0100).
**Assumed working until a suitable channel appears:** R09 audio and subtitle selection; HEVC recording playback.
R14/R16/R19 are superseded by roadmap A2.1 (the UIKit guide) once that's accepted.

## 4. Architecture

- **Screens:** `ContentView` → launch/onboarding/unreachable → `LibraryView` tab container (Guide, Recordings, Settings; `ChannelDetails`/`FavouriteControl` in `LibraryView.swift`). Player is presented full screen via `PlayerHost` → `PlayerScreen` → `CustomPlayerView` (tvOS) or `NativePlayer` (iOS).
- **Guide focus model:** `GuideFocus(channel, start)`; `start == nil` is the channel tile, `-1` the no-EPG placeholder. tvOS focus engine moves between drawn cells; `navigate()` intervenes only when the target is off-screen. `viewport` (half-hour aligned) drives rendering; `model.window` drives 24-hour data loads.
- **Player layering:** conflict/error/reconnecting states replace the player. **tvOS:** `CustomPlayerView` (`CustomPlayer.swift`) is the only player — `PlayerLayerView` video + one overlay switching between hidden / info / scrub / channels / tracks chrome, driven by in-view remote handlers, no AVKit. **iOS/iPadOS:** `NativePlayer` (plain AVKit) + top controls, with `QuickGuidePanel` as the channel sheet.
- **Design rules:** page background `PigPageBackground`; surfaces `Color.guideCell` + `PigSurfaceButtonStyle` (pink accent outline on focus); tvOS type scale in `GuideTypography`; player overlays force dark scheme and provide an opaque fallback for Reduce Transparency. New screens reuse these rather than defining new styles.

## 5. Implementation map and constraints

| Files | Responsibility / things to preserve |
|---|---|
| `Models.swift`, `APIClient.swift` | Info/errors/resolve payloads, status decoding, URL/auth rules. Optional conflict envelope preserves the strict recording type. Status-aware responses support bounded recording polling. Diagnostics strip queries and retain bearer authentication. |
| `AppModel.swift` | Auth and model construction, channel switching. Validated info is retained on the authenticated APIClient through restore/login/pairing and exposed in Settings; logout clears it. Rate-limit cooldown stops immediate repeat auth attempts. |
| `PlaybackModel.swift`, `ContentView.swift`, `CustomPlayer.swift`, `PlayerExtras.swift` (iOS channel sheet) | Player lifecycle, presentation, prompts and controls. `ready` means item installed; actual `.playing` supplies prior-play evidence. Recovery clears the item without permanently ending the model; `stop()` is terminal. Guards coalesce failures and reject stale callbacks/repeated appearances. Late resolve sessions still get released. |
| `RecordingPlayback.swift` | Native recording preparation/playback and skip/resume. Startup Task is retained/cancelled, checked after suspension points, and awaited before audio teardown. Generation checks reject stale callbacks after retry. 404 wording covers missing recordings and older servers without assuming either. |
| `BrowseModel.swift`, `GuideView.swift`, `ChannelArtwork.swift` | Guide/cache/artwork; avoid full-day horizontal views and cross-row scroll feedback (previous rendering instability). Gate artwork-index launch and preserve lightweight logo fetching. |
| `DVRModels.swift`, `RecordingsView.swift` | Recording states/actions and guide schedule identity; preserve milliseconds versus seconds. |
| `PigTVTests/ContractChecks.swift`, `Tools/test-contracts.sh` | Synthetic contract fixtures and local runner. Targeted simulator lifecycle tests live in `PigTVTests/PlaybackLifecycleTests.swift`; the standalone runner covers API/model fixtures. The scheme sets `PIGTV_SYNTHETIC_TESTS=1` so the test host cannot restore a saved real-server session. |

C2 recovery uses actual playing evidence, allows one automatic attempt per user-initiated playback attempt, and coalesces failure callbacks. A second failure or failed resolve requires Retry; a 409 still requires explicit takeover. Mark confirmed return-to-guide behaviour on 21 September: background cleanup ends playback; foreground return must not automatically resume or reconnect the last channel. Automatic recovery applies only while the player remains active. A stream idle ≥60 seconds can be reclaimed on demand; the idle sweep is five minutes. Confirm AVPlayer paused-fetch behaviour on a real device.

C3: `APIClient.requestURL` rejects `?` in paths; use structured query items. A terminal 500 must stop polling because another request starts a new transcode attempt. Continue using the recording list's duration for resume bounds; playback `durationSec` is wall-clock length.

## 6. Shared contracts and coordination

- Guide rows use `id/sourceId/name/logo/category/tvgId/programmes`, with programme `startTime/endTime` in **milliseconds**. Marker `startMs/endMs` also use milliseconds.
- Favourites writes use bare channel IDs; source-qualified IDs remain useful for local UI identity. Read favourites from `library/favourites`.
- Resolve sends `capabilities.segmentedDelivery = true`. “transcode” strategy can mean video/audio copy into HLS, not re-encoding.
- Approved media paths: `/api/proxy/stream`, `/api/transcode/…`, `/api/recordings/…` (`/api/remux` was retired by server 0103 and removed from the client's allow-list and strategy lists in A0.1); tokens on approved media URLs, bearer on session DELETE. Do not broaden URL acceptance to fix playback.
- Recording playback: bearer-authenticated `/api/recordings/{id}/playback`; MP4 response with same-server `media.mp4`, token query and byte-range seeking. Async preparation is additive and opt-in.
- Optional flags: `viewerConflict`, `epgLogoFallback`, `clientEvents`, `scheduledWaiting`, `recordingPlaybackPolling`, `playbackTerminalStatus`. C1/C2 must also handle servers whose behaviour predates the flags.
- Adding a client endpoint requires a coordinated addition to server `test/api-404.test.js` → `APPLE_CLIENT_ROUTES`; C7 now calls `POST /api/playback/client-event`; the guard addition is now on local server `main` at `6f8148b`, fast-forwarded from `swift/client-0086-contract-docs` on 21 September without changing runtime code. This server test has not run: Node is not on PATH and server node_modules are absent; no dependencies were downloaded.
- Server 0085/0086 require device regression testing, not client payload changes: copied-video timing/smoothness/lip-sync and finite-source pacing (provider stream `1803789`).
- **Server handoff §5, reviewed to build 0099 (22 September):** 0097 makes favourites follow a reorder-stable channel identity and adds an optional **`stableId`** (client decodes it, R12); 0098 extends it to recordings/history; **0099 ships SR-2** — the small-caps badge is stripped at ingest (client stripper now redundant, R15). All "None to code" — no response shape changes.
- **Open client → server requests in [docs/SERVER-REQUESTS.md](docs/SERVER-REQUESTS.md):** SR-2 (badge) **shipped as 0099**. SR-1 (HDR colour signalling in the HLS copy, client R13) is **still open** — hand it to the server workflow.
- Read server handoff §5 at each integration session. Describe any server request by required user-visible behaviour and record the dependency here. The local server blueprint and Swift handoff now reference this client blueprint instead of its retired handovers. Those were the original client integration changes. The server developer subsequently added the 0094 runtime contract. This review makes no server-repository changes.

## 7. Deferred choices

**Confirmed by Mark, 21 September:** target server build 0086 matched the local server folder at that time (local server is now 0094; deployed build unconfirmed); retain return to guide after backgrounding. The client agent handles synthetic tests and simulator validation. The later review request also authorises testing via Xcode on the downstairs TV; Mark can conduct physical Apple TV and multi-device acceptance. Simulator results do not establish real-provider playback or hardware correctness. Network access still requires approval.

- No session keep-alive planned: recovery is needed regardless and idle reclamation protects recordings. Revisit only if actual pause usage requires it.
- HEVC recording playback remains unverified on hardware. Old server `.native.mp4` sidecars may carry `hev1`; any cleanup is a separate approved server operation, not a client workaround.
- Minimum OS versions/supported devices and distribution/versioning policy need agreement before release. Do not inherit the server patch number as the Swift build number.
- AirPlay, PiP and background playback remain outside current scope; preserve existing restrictions until session ownership supports them.
- Avoid speculative VOD/series work. Guide/player changes are now explicitly scoped in §4a; the implemented channel browser still needs device UX acceptance.

# PigTV Swift client — blueprint

**Last updated: 21 September 2026.** Single source of truth for client plans, current implementation, verification and developer transition. Read this first; update it with each change and at session end. Condense superseded facts rather than appending chat narratives.

## 1. Direction and working rules

Develop the native SwiftUI/AVKit client for Apple TV, iPad and iPhone alongside the PigTV server. Prioritise playback stability and quality, then everyday guide/navigation usability. The server owns stream preparation and provider arbitration; the client owns native presentation and recovery.

- Mark requires approval before **any internet usage**, including fetch/pull, remote GitHub access, browsing or dependency downloads. No internet or deployed-server access has been used in this integration session. Obtain approval before contacting the deployed server for integration tests as well.
- Ask before commits to main, pushes, merges, deployment or publication. Work locally on feature branches; no commits have been made in this session; do not infer approval to publish from approval to edit.
- Never send `force: true` automatically. Viewer/recording takeover requires an explicit user choice.
- Preserve same-origin authentication, media URL allow-listing, capability negotiation and release-before-switch behaviour. Browsing/focus must not acquire a provider stream.
- Keep server work coordinated and separately scoped. Do not copy the server's Windows patch-delivery workflow into this client repository.

## 2. Orientation and source of truth

| Item | Current reference |
|---|---|
| Client | This repository, `PigTV.xcodeproj`, shared scheme `PigTV` |
| Local client | `/Users/markrogers/Documents/GitHub/PigTV-Swift` |
| Local server | `/Users/markrogers/Documents/GitHub/PigTV` |
| Server integration | [Swift handoff](../PigTV/docs/SWIFT-CLIENT-HANDOFF.md), C1–C9 and §5 change log |
| Server roadmap | [Server blueprint](../PigTV/blueprint.md) |
| Developer entry point | [README.md](README.md) |
| Regression procedure | [TESTING.md](TESTING.md) |
| Historical notes | [docs/archive](docs/archive); frozen, not current instructions |

Baseline reviewed: client commit `c88baf8` (Initial Commit); app version/build `1.0 (1)`; project targets iOS/tvOS 26.5. These are local source facts, not a claim about the installed app. Current working app version/build: **1.0 (2)** on branch `swift/server-0086-integration`. Final minimum OS/device support remains undecided.

Mark confirmed on 21 September that the deployed server matches the local PigTV repository, **build 0086**. This is user-confirmed, not independently queried. Once network testing is approved, record `/api/info` build/display and flags. Gate optional behaviour on flags, not numeric build comparisons. The old Codex/OneDrive working-copy paths and claims that the client is not in Git are obsolete.

## 3. Implemented baseline and evidence

“Implemented” means present in source; it does not imply physical-device verification.

| Area | Implemented | Verification still owed |
|---|---|---|
| Setup/auth | Origin validation, login, pairing, Keychain, compatibility checks, unreachable-server retry | Current build reconnect/sign-in flows |
| Guide | Windowed rendering; two-hour TV/iPad and one-hour iPhone viewport; 24-hour paged data; background preload; cached guide; categories/favourites; programme search; remembered position | Physical remote left/right, category scrolling, return focus, touch layouts |
| Live player | Native AVKit, segmented delivery, codec detection, release before channel switch, Channels sheet, next/previous/back, now/next metadata, Go to live | Current-server long playback, same-device switching, latest Channels sheet and metadata |
| Recordings | Schedule/cancel/stop/delete, status display, native MP4 playback, resume, break markers, manual/automatic skip | Long preparation, HEVC, seek/resume/skip, waiting status lifecycle |
| Coordination | Viewer/recording confirmation, five-second prompt poll, decline handling, one recovery attempt and cleanup | Real two-device takeover, expired-session recovery and long pause |
| Appearance/artwork | Logo cache/fallback, pig branding, app icons/top shelf, System/Light/Dark | Latest logo backings, light-mode persistence, tab legibility, iPhone/iPad and accessibility |

Historical evidence: Mark confirmed live playback working on 15 September. The 16 September handoff reports a build installed on physical Apple TV “Upstairs Living Room,” with latest UI checks still pending. This does not establish current-server compatibility or HEVC recording playback.

**Fresh evidence, 21 September:** the local runner passes **123 synthetic API/model checks** (baseline was 93). Final build **1.0 (2)** passed on Apple TV/tvOS 26.5 and iPad Pro 13-inch (M5)/iOS 26.5 using Xcode 27.0: **11 XCTest tests, zero failures on each** (123 contract checks plus 10 lifecycle tests). The only build warnings were skipped App Intents metadata extraction; no Swift compiler warnings. No physical-device or deployed-server test has been run by the agent.

## 4. Implementation roadmap

C1–C8 and capability plumbing are implemented locally; physical-device verification is the next milestone. Preserve C identifiers from the server handoff. Status vocabulary: **Planned → In progress → Implemented, verification pending → Verified**; use **Blocked** with a named dependency or **Deferred** with a reason. Record implementation and device evidence separately.

| Order / ID | Status | Deliverable and acceptance |
|---|---|---|
| 0 / D0 | Complete locally | Consolidate current knowledge into this blueprint, archive the two handovers, refresh README/testing guidance. No commit. |
| 1 / F0 + C8 | Implemented; device checks pending | Retain optional server features/build/display across restore, login and pairing; pass capabilities to consuming models; clear on server/account change. Settings shows server identity beside app identity. Old info responses still decode and keep legacy behaviour. |
| 2 / C1 | Implemented; device checks pending | Decode viewer and recording conflicts via a tolerant envelope; preserve strict recording data where required. Show server viewer message, explicit takeover/cancel; malformed or unknown conflicts fail safely. No implicit force retry. |
| 3 / C2 | Implemented; device checks pending | Distinguish initial failure from playback that later ends. Release and re-resolve once without force; show Reconnecting, then a user Retry if recovery fails. Recovery 409 uses C1. Handle failed playback after a long pause while still in the player, without loops or reviving dismissed players. Background return stays on the guide. |
| 4 / C3 | Implemented; device checks pending | Feature-gated `async=1` recording request; distinguish 200/202; cancellable Preparing state; bounded polling using retry delay (overall limit 10 minutes). Stop on dismissal; explain missing-file/remux failure and require explicit retry. Legacy servers retain blocking path. |
| 5 / C4 | Implemented; device checks pending | With `epgLogoFallback`, skip the entire client EPG artwork-index request; use server logo. Retain fallback for older servers and preserve origin-scoped bearer handling. |
| 6 / C5 | Implemented; device checks pending | Explain waiting schedules as waiting for a viewer; validate cancellation and duplicate prevention; distinguish scheduled/waiting from actively recording in guide badges. Cancellation already supports waiting; status now explains the viewer delay. Existing guide channel badges include only actively recording channels. |
| 7 / C6 | Implemented; device checks pending | Decode 429 retry delay for login/pairing, show actionable retry timing and prevent aggressive retries. Add malformed/missing-delay fallback. |
| 8 / C7 | Implemented; device checks pending | Feature-gated, best-effort media-error/play-start/play-end diagnostics with sanitised fields, path only and no tokens/query strings. Never delay or fail playback because logging failed. Capture stalls and durations once per play. |
| 9 / V1 | Planned | Complete the physical Apple TV regression matrix plus iPad/iPhone checks; fix observed usability defects and record device/app/server identities with results. |
| C9 | Deferred | Audio-only re-encode retry only if an actual AVPlayer audio-decoding failure justifies it; no speculative retry. |

Next: Mark installs app 1.0 (2) and exercises V1 against server 0086. No runtime server patch is required by C1–C8. C9 remains deliberately deferred.

## 5. Implementation map and constraints

| Files | Responsibility / things to preserve |
|---|---|
| `Models.swift`, `APIClient.swift` | Info/errors/resolve payloads, status decoding, URL/auth rules. Optional conflict envelope preserves the strict recording type. Status-aware responses support bounded recording polling. Diagnostics strip queries and retain bearer authentication. |
| `AppModel.swift` | Auth and model construction, channel switching. Validated info is retained on the authenticated APIClient through restore/login/pairing and exposed in Settings; logout clears it. Rate-limit cooldown stops immediate repeat auth attempts. |
| `PlaybackModel.swift`, `ContentView.swift`, `PlayerExtras.swift` | Player lifecycle, presentation, prompts and controls. `ready` means item installed; actual `.playing` supplies prior-play evidence. Recovery clears the item without permanently ending the model; `stop()` is terminal. Guards coalesce failures and reject stale callbacks/repeated appearances. Late resolve sessions still get released. |
| `RecordingPlayback.swift` | Native recording preparation/playback and skip/resume. Startup Task is retained/cancelled, checked after suspension points, and awaited before audio teardown. Generation checks reject stale callbacks after retry. 404 wording covers missing recordings and older servers without assuming either. |
| `BrowseModel.swift`, `GuideView.swift`, `ChannelArtwork.swift` | Guide/cache/artwork; avoid full-day horizontal views and cross-row scroll feedback (previous rendering instability). Gate artwork-index launch and preserve lightweight logo fetching. |
| `DVRModels.swift`, `RecordingsView.swift` | Recording states/actions and guide schedule identity; preserve milliseconds versus seconds. |
| `PigTVTests/ContractChecks.swift`, `Tools/test-contracts.sh` | Synthetic contract fixtures and local runner. Targeted simulator lifecycle tests live in `PigTVTests/PlaybackLifecycleTests.swift`; the standalone runner covers API/model fixtures. The scheme sets `PIGTV_SYNTHETIC_TESTS=1` so the test host cannot restore a saved real-server session. |

C2 recovery uses actual playing evidence, allows one automatic attempt per user-initiated playback attempt, and coalesces failure callbacks. A second failure or failed resolve requires Retry; a 409 still requires explicit takeover. Mark confirmed return-to-guide behaviour on 21 September: background cleanup ends playback; foreground return must not automatically resume or reconnect the last channel. Automatic recovery applies only while the player remains active. A stream idle ≥60 seconds can be reclaimed on demand; the idle sweep is five minutes. Confirm AVPlayer paused-fetch behaviour on a real device.

C3: `APIClient.requestURL` rejects `?` in paths; use structured query items. A terminal 500 must stop polling because another request starts a new remux attempt. Continue using the recording list's duration for resume bounds; playback `durationSec` is wall-clock length.

## 6. Shared contracts and coordination

- Guide rows use `id/sourceId/name/logo/category/tvgId/programmes`, with programme `startTime/endTime` in **milliseconds**. Marker `startMs/endMs` also use milliseconds.
- Favourites writes use bare channel IDs; source-qualified IDs remain useful for local UI identity. Read favourites from `library/favourites`.
- Resolve sends `capabilities.segmentedDelivery = true`. “transcode” strategy can mean video/audio copy into HLS, not re-encoding.
- Approved media paths: `/api/proxy/stream`, `/api/remux`, `/api/transcode/…`, `/api/recordings/…`; tokens on approved media URLs, bearer on session DELETE. Do not broaden URL acceptance to fix playback.
- Recording playback: bearer-authenticated `/api/recordings/{id}/playback`; MP4 response with same-server `media.mp4`, token query and byte-range seeking. Async preparation is additive and opt-in.
- Optional flags: `viewerConflict`, `epgLogoFallback`, `clientEvents`, `scheduledWaiting`, `recordingPlaybackPolling`. C1/C2 must also handle servers whose behaviour predates the flags.
- Adding a client endpoint requires a coordinated addition to server `test/api-404.test.js` → `APPLE_CLIENT_ROUTES`; C7 now calls `POST /api/playback/client-event`; the guard addition is in the local server branch `swift/client-0086-contract-docs`. This server test has not run: Node is not on PATH and server node_modules are absent; no dependencies were downloaded.
- Server 0085/0086 require device regression testing, not client payload changes: copied-video timing/smoothness/lip-sync and finite-source pacing (provider stream `1803789`).
- Read server handoff §5 at each integration session. Describe any server request by required user-visible behaviour and record the dependency here. The local server blueprint and Swift handoff now reference this client blueprint instead of its retired handovers. These references and the route guard are the only server-repository changes; no server runtime code or build number changed.

## 7. Deferred choices and open verification

**Confirmed by Mark, 21 September:** target server build 0086 matches the local server folder; retain return to guide after backgrounding. The client agent handles synthetic tests and local Xcode simulator validation; Mark handles physical Apple TV and multi-device testing. Simulator results do not establish real-provider playback or hardware correctness. Network access still requires approval.

- No session keep-alive planned: recovery is needed regardless and idle reclamation protects recordings. Revisit only if actual pause usage requires it.
- HEVC recording playback remains unverified on hardware. Old server `.native.mp4` sidecars may carry `hev1`; any cleanup is a separate approved server operation, not a client workaround.
- Minimum OS versions/supported devices and distribution/versioning policy need agreement before release. Do not inherit the server patch number as the Swift build number.
- AirPlay, PiP and background playback remain outside current scope; preserve existing restrictions until session ownership supports them.
- Avoid speculative VOD/series or broad guide redesign work during this integration pass.

## 8. Session transition protocol

At the start: read this file, inspect local branch/status, read server handoff §5 for changes since last review, and choose the next planned item. Do not fetch or contact the server without approval.

At the end: update roadmap status, record exact checks and failures, distinguish historical reports from current evidence, retain only durable decisions, and leave one concrete next action. Keep detailed test procedures in TESTING.md and old narratives in the archive. Do not create new dated handover files.

**Current transition:** C1–C8/F0 implemented locally as app 1.0 (2); client branch `swift/server-0086-integration`, server test/docs branch `swift/client-0086-contract-docs`. Final simulator verification passed on both tvOS and iOS; 123 standalone checks and 10 lifecycle tests pass. Remaining acceptance is physical-device/provider testing. No commits, pushes, internet or deployed-server requests. Mark owns the next physical Apple TV/multi-device checks; start with Settings identity, takeover in both directions, a six-minute pause, and long/HEVC recording playback. See TESTING.md for the full matrix.

# PigTV Swift client — blueprint

**Last updated: 21 September 2026.** Single source of truth for client plans, current implementation, verification and developer transition. Read this first; update it with each change and at session end. Condense superseded facts rather than appending chat narratives.

## 1. Direction and working rules

Develop the native SwiftUI/AVKit client for Apple TV, iPad and iPhone alongside the PigTV server. Prioritise playback stability and quality, then everyday guide/navigation usability. The server owns stream preparation and provider arbitration; the client owns native presentation and recovery.

- Mark requires approval before **any internet usage**, including fetch/pull, remote GitHub access, browsing or dependency downloads. No internet or deployed-server access has been used in this integration session. Obtain approval before contacting the deployed server for integration tests as well.
- **Main-only workflow (Mark, 21 September):** make future changes directly in this repository’s `main` working folder. Mark authorises local commits to `main` for testing; do not create feature branches/worktrees for routine work. Confirm the folder contains the latest local work before editing; preserve unrelated user changes. Internet access, pushes, deployment and publication still require approval. Current request authorises scoping/documentation only, **no app coding**.
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

Baseline reviewed: client commit `c88baf8` (Initial Commit); app version/build `1.0 (1)`; project targets iOS/tvOS 26.5. These are local source facts, not a claim about the installed app. Current working app version/build: **1.0 (2)** on **`main`**, including integration commit `4b1b15b` and subsequent local main commit `29c0500`. Final minimum OS/device support remains undecided.

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
| 2 / C1 | Implemented; device-reported defect — U02 | Decode viewer and recording conflicts via a tolerant envelope; preserve strict recording data where required. Show server viewer message, explicit takeover/cancel; malformed or unknown conflicts fail safely. No implicit force retry. |
| 3 / C2 | Implemented; takeover interaction under investigation — U02 | Distinguish initial failure from playback that later ends. Release and re-resolve once without force; show Reconnecting, then a user Retry if recovery fails. Recovery 409 uses C1. Handle failed playback after a long pause while still in the player, without loops or reviving dismissed players. Background return stays on the guide. |
| 4 / C3 | Implemented; device checks pending | Feature-gated `async=1` recording request; distinguish 200/202; cancellable Preparing state; bounded polling using retry delay (overall limit 10 minutes). Stop on dismissal; explain missing-file/remux failure and require explicit retry. Legacy servers retain blocking path. |
| 5 / C4 | Implemented; device checks pending | With `epgLogoFallback`, skip the entire client EPG artwork-index request; use server logo. Retain fallback for older servers and preserve origin-scoped bearer handling. |
| 6 / C5 | Implemented; device checks pending | Explain waiting schedules as waiting for a viewer; validate cancellation and duplicate prevention; distinguish scheduled/waiting from actively recording in guide badges. Cancellation already supports waiting; status now explains the viewer delay. Existing guide channel badges include only actively recording channels. |
| 7 / C6 | Implemented; device checks pending | Decode 429 retry delay for login/pairing, show actionable retry timing and prevent aggressive retries. Add malformed/missing-delay fallback. |
| 8 / C7 | Implemented; device checks pending | Feature-gated, best-effort media-error/play-start/play-end diagnostics with sanitised fields, path only and no tokens/query strings. Never delay or fail playback because logging failed. Capture stalls and durations once per play. |
| 9 / V1 | In progress — Mark reported U01–U11 | Complete the physical Apple TV regression matrix plus iPad/iPhone checks; fix observed usability defects and record device/app/server identities with results. |
| C9 | Deferred | Audio-only re-encode retry only if an actual AVPlayer audio-decoding failure justifies it; no speculative retry. |

Mark has begun app testing and reported the issues/features in §4a. Those reports supersede any assumption that the simulator pass establishes device acceptance. No new fixes are implemented in this scoping pass. C9 remains deliberately deferred; U02 may require coordinated server/web work after diagnosis.

## 4a. Device feedback and next scope — 21 September 2026

**Source/status:** Mark’s in-app testing report. **U05 is implemented locally, verification pending; U02 is diagnosed and blocked on a coordinated server contract; all other U-items below remain Scoped — not implemented.** Device model, OS, exact tested client build, login/pairing mode and takeover direction were not captured in the report; record them at reproduction. Existing simulator results remain valid for the tested contracts, not proof these UI/device behaviours work.

**Suggested sequence:** diagnose U02/U05 first; stabilise guide layout/navigation (U01/U06); unify visual treatment (U03/U04/U08/U07); design launch presentation (U09); then research/design player information and channel browsing together (U10/U11). P1 = functional failure; P2 = usability/readability; P3 = enhancement. These priorities are proposed, not additional feature requirements.

| ID | Priority | Requested outcome | Acceptance / verification |
|---|---|---|---|
| U01 | P2 | Fixed guide description area, approximately two lines, with explicit expansion for longer text. | Empty, short and long descriptions reserve the same collapsed height; changing focused programme never shifts guide rows vertically. Expand/collapse exposes the full description without losing programme focus or time position; agree sheet/overlay treatment before implementation. |
| U02 | P1 — Blocked on server contract | Reliable takeover when another client is already watching; the chosen new client plays and the original client stops cleanly. | Cancel preserves the original viewer; explicit takeover starts the new viewer. Original client does not silently reclaim the stream or repeatedly retry; present a useful stopped/taken-over state where supported. Test both directions, paired devices and password login on the same account, and preserve same-device channel switching/recording-conflict protections. |
| U03 | P2 | Category strip retains its current usable width, with real transparency fades only at edges hiding more content; remove black bands. | At the initial left boundary: left fully visible, right fades if more categories exist. In the middle: both edges fade. At the final right boundary: right fully visible, left fades. No overflow: neither fades. Verify exact boundaries, focus highlight, remote scrolling and both appearances. |
| U04 | P2 | Fix Recordings tab contrast, specifically unfocused recording entries and unfocused Refresh; match the legible pink/text treatment of the TV Guide tab. | Compare focused, unfocused, selected, disabled and pressed states in light/dark mode. Reuse the existing guide’s readable foreground/background pairing instead of assuming a new text colour; no hard-to-read black-on-pink instances in the reported states. |
| U05 | P1 — Implemented locally, verification pending | Settings must remain visible and usable after changing System/Light/Dark appearance. | Repeatedly select each appearance; Settings never becomes blank, focus stays usable, and the chosen setting persists across launch and playback. Check TV first, then touch platforms; capture any rendering/runtime errors. |
| U06 | P2 | Smooth horizontal guide movement and dependable return to the initial guide position. | Rightward viewport changes feel comparable to vertical scrolling, without double jumps or lost focus. After moving several screens right, repeated left navigation always returns to the correct initial/live baseline. Verify short/long programmes, gaps, held remote input, channel changes and half-hour boundaries. Define the baseline relative to current time so an old launch time is not frozen indefinitely. Respect Reduce Motion; preserve bounded rendering. |
| U07 | P2 | Remove the pink backing from the app icon; retain the pig logo. | Review actual iOS light/dark/tinted and tvOS layered/store icons: no added pink disc/backplate, pig proportions/sharpness preserved. Confirm platform-required opaque/layer treatment before export. Top Shelf and in-app branding are not automatically included in this icon-only change. |
| U08 | P2 | One consistent, darker translucent backing filling each guide logo tile; remove the smaller/lighter nested box. | The tile uses its full allotted area and a single backing darker than the guide surface, with matching transparency treatment. Logos use the available area while preserving aspect ratio; no automatic crop/stretch. Test transparent light/dark/mixed marks, opaque provider images and missing-logo TV fallback. Embedded backgrounds in provider artwork may remain; do not mistake those for an app-added box. |
| U09 | P3 | Branded splash/loading screen on initial app launch. | Define cold-launch presentation and handoff to sign-in/cached guide/loading/error. Avoid blank flashes and arbitrary minimum delays; an unreachable server cannot strand the splash. Do not replay on ordinary foreground return, which continues to show the guide. Distinguish static system launch screen from SwiftUI loading state during design. |
| U10 | P3 | Programme information on the main player overlay, without needing to open the separate Info section; Back first closes the overlay. | Proposed contents: channel, current programme, times/progress and a concise description. With overlay visible, Back hides it and playback continues; with it hidden, Back returns to guide. Test transport controls, channel browser and nested panels so Back dismisses the topmost layer, not the player underneath. Define tvOS AVKit integration before replacing native controls. |
| U11 | P3 | Completely refresh in-player channel selection: translucent presentation showing channels above/below the current selection and what is on now. | Research leading TV/IPTV interfaces, compare patterns, then agree a design before coding. Current channel is obvious; adjacent channels show current programme (and graceful missing-EPG fallback), remote focus/scrolling is predictable, and switching releases the old stream first. Browsing alone never resolves media. Preserve useful channel order/filter context; close browser back to playback. Test long lists, edge channels, legibility over bright/dark video and Reduce Transparency. |

### Investigation notes for the next developer

- **U01 — `GuideView.swift`:** the selected-programme summary already limits text to two lines, but the surrounding block uses a *minimum* height. Line limit alone does not reserve a fixed height; consider a stable collapsed summary region and separate expanded presentation. Keep title/actions stable as well.
- **U02 — evidence, not a diagnosis:** [attached server-log excerpt](docs/evidence/2026-09-21-takeover-server-log.png) shows the coordinator releasing the prior session at 1 s idle, stopping ffmpeg, deleting its session directory, a subsequent playlist 404 for that removed session, then a new session starting. It therefore shows server-side termination; it does **not** prove the new client successfully played, which client emitted the visible error, or that only one session remained afterwards. A short continuation from buffered media can also look like the old viewer did not stop.
- **U02 — diagnosed contract gap:** `PlaybackModel` correctly treats a post-playback media failure as an expired/stalled session and makes one C2 recovery attempt. The server removes a session on forced takeover without communicating that reason to the removed client; its AVPlayer therefore sees the same playlist/segment failure as an ordinary expiry. For password login, both clients are `user:<id>` owners, so that recovery can release the new client’s session without a new confirmation. Paired devices use distinct `device:<id>` owners but still cannot distinguish takeover from expiry after their session is removed. Do not solve this by unconditionally forcing playback, disabling C2 recovery, or special-casing paired devices. Required coordinated server behaviour: retain a short-lived, owner-scoped terminal reason for a removed session and expose an additive, feature-gated status lookup that returns `taken-over` only to the session’s former owner. On that result, the client stops cleanly with a taken-over state; absent/older endpoint results retain existing C2 recovery. Add server and Swift fixtures for forced takeover, expiry, legacy fallback and password/paired ownership.
- **U03 — `GuideView.swift`:** current strip draws page-coloured gradients over *both* edges unconditionally. The requested effect is content fading into the underlying surface, conditional on actual overflow. A previous naive mask disrupted tvOS focus/scrolling (archived handover); validate a focus-safe approach rather than blindly restoring it.
- **U04/U05:** inspect `RecordingsView.swift`, `TVActionStyle.swift`, guide control styling, `LibrarySettings` and the `PigTVApp` window-level appearance modifier. Blank Settings root cause is unconfirmed; reproduce before changing appearance architecture.
- **U06:** inspect `GuideNavigation.reveal`, `setViewport`, disabled finished programmes, the split between native focus and `onMoveCommand`, and the delayed focus reapplication. Animate a coordinated window transition; do not reintroduce the old full-day row scrolling/render feedback loop merely to obtain smooth motion.
- **U07/U08:** icon source is in `Assets.xcassets`; guide tile composition is shared by `GuideView.swift` and `ChannelArtwork.swift`. Separate tile background from image-fit sizing; review actual pixels/layout before changing assets.
- **U10/U11:** inspect `PlayerExtras.swift` and `ContentView.swift`. Current AVKit Info metadata is separate from transport chrome, and the SwiftUI player has a broad `.onExitCommand { dismiss() }`. Establish ownership of overlay visibility and Back handling; preserve native seeking, play/pause, captions/audio and Go to live. Reuse cached guide now/next data and refresh programme boundaries while the browser is open.
- **Research approval:** no internet research has been done for U11. When implementation/design is authorised, request internet approval before checking current leading-provider interfaces and Apple platform guidance. Deliver linked examples, a short comparison of useful navigation/overlay patterns, platform feasibility and an agreed wireframe; do not assume a provider’s capabilities from memory.

**Verification for future fixes:** add focused tests for takeover/ownership/recovery and guide viewport boundaries where feasible; build/run simulator regressions; Mark validates physical remote interaction, transparency/contrast and both-device playback. Record actual client/server build identities and outcomes per U-item. Keep this backlog in the blueprint; do not create new dated handover narratives.

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
- Adding a client endpoint requires a coordinated addition to server `test/api-404.test.js` → `APPLE_CLIENT_ROUTES`; C7 now calls `POST /api/playback/client-event`; the guard addition is now on local server `main` at `6f8148b`, fast-forwarded from `swift/client-0086-contract-docs` on 21 September without changing runtime code. This server test has not run: Node is not on PATH and server node_modules are absent; no dependencies were downloaded.
- Server 0085/0086 require device regression testing, not client payload changes: copied-video timing/smoothness/lip-sync and finite-source pacing (provider stream `1803789`).
- Read server handoff §5 at each integration session. Describe any server request by required user-visible behaviour and record the dependency here. The local server blueprint and Swift handoff now reference this client blueprint instead of its retired handovers. These references and the route guard are the only server-repository changes; no server runtime code or build number changed.

## 7. Deferred choices and open verification

**Confirmed by Mark, 21 September:** target server build 0086 matches the local server folder; retain return to guide after backgrounding. The client agent handles synthetic tests and local Xcode simulator validation; Mark handles physical Apple TV and multi-device testing. Simulator results do not establish real-provider playback or hardware correctness. Network access still requires approval.

- No session keep-alive planned: recovery is needed regardless and idle reclamation protects recordings. Revisit only if actual pause usage requires it.
- HEVC recording playback remains unverified on hardware. Old server `.native.mp4` sidecars may carry `hev1`; any cleanup is a separate approved server operation, not a client workaround.
- Minimum OS versions/supported devices and distribution/versioning policy need agreement before release. Do not inherit the server patch number as the Swift build number.
- AirPlay, PiP and background playback remain outside current scope; preserve existing restrictions until session ownership supports them.
- Avoid speculative VOD/series work. Guide/player changes are now explicitly scoped in §4a; research/design comes before implementing the player channel-browser redesign.

## 8. Session transition protocol

At the start: read this file, inspect local branch/status, read server handoff §5 for changes since last review, and confirm `main` is checked out and contains the latest local work, then choose the next authorised item. Never apply historical stashes merely because they exist. Do not fetch or contact the server without approval.

At the end: update roadmap status, record exact checks and failures, distinguish historical reports from current evidence, retain only durable decisions, and leave one concrete next action. Keep detailed test procedures in TESTING.md and old narratives in the archive. Do not create new dated handover files.

**Current transition:** local `main` is now the working branch in both repositories. Swift `main` already contained integration commit `4b1b15b` (app 1.0 (2)); server `main` was fast-forwarded to existing commit `6f8148b` to retain its client documentation/route-guard updates. No remote fetch/push was performed, so “latest” here means latest available local work. Historical GitHub Desktop stashes/branches were not applied or deleted; unrelated Finder/Xcode UI state is preserved. U02 is now diagnosed as a coordinated server-contract requirement; no server changes were made. U05 removes the presentation-only Settings background in favour of an ordinary view background; it passes 123 synthetic API/model checks and an offline tvOS Simulator build, but still needs physical Apple TV and touch-platform validation. Next: agree U01’s expanded-description presentation; separately authorise/implement the U02 server contract, then add the feature-gated Swift handling and device matrix. Main commits for testing are authorised; internet/pushes still need approval.

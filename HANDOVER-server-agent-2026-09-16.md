# PigTV handover — 16 September 2026 (end of Claude/Cowork session)

Audience: the server agent (and Mark). This supersedes the earlier chat notes. The Apple client's own running log is `HANDOVER.md` inside the Xcode project.

## 1. State of the Apple client (tvOS / iPad / iPhone)

Working project: `/Users/markrogers/Documents/Codex/2026-09-13/i-ve/work/PigTV-Apple/PigTV.xcodeproj` (file-system-synchronised groups; new files are picked up automatically). Latest build compiled with warnings only and was installed on the physical Apple TV "Upstairs Living Room" from Xcode at the end of the session. Not yet published to Git.

Done this session (all in the working project):
- Guide rebuilt: windowed rendering (2 h on TV/iPad, 1 h on iPhone), 24 h of data cached in memory and on disk, background page preload, logo tiles with a single charcoal backing (dark mode) / mid-grey (light mode) for transparent logos, sticky captions, record badges, programme search, remembered position, category strip with soft edges (overlay, not mask — a mask stopped the strip scrolling), iPhone icon-only header.
- Remote navigation: single-step left/right; when the target programme is off-screen the viewport shifts and focus is re-applied after the focus engine's own move (fixes "left goes to the channel tile instead of the live programme"). Finished programmes are dimmed and disabled.
- Player: in-place channel switching (previous stream released first), transport-bar "Channel" menu with **Channels…** (opens a SwiftUI sheet — the AVKit custom info panels were not focusable on the real Apple TV and have been removed), Next/Previous channel, Back to last channel, and a **Go to live** contextual action when >20 s behind the live edge. Now/next is carried in item metadata: title = programme, subtitle = channel • times • Next: …, description = synopsis + "Coming up" list; refreshed every 5 s as programmes change. This is the text the system shows on swipe-up.
- Appearance: `preferredColorScheme` moved to the WindowGroup so the player cannot flip the guide back to dark; tint applied per tab (the tab bar's selected label was pink-on-grey); guide cells use a darker surface in light mode.
- Recording playback client: `RecordingPlayerScreen` (resume, Skip break, Auto-skip) against `GET /api/recordings/{id}/playback` → `media.mp4?token=`.
- Resilience: disk cache of the guide, 15-min refresh, "Can't reach PigTV" screen with retry.
- Branding: iOS icons and tvOS layered icon + top shelf generated from the pig logo.

Not yet verified on device by Mark (test next): categories now scrollable; left-navigation fix; single logo backing; tab-bar legibility; light-mode surfaces; Channels… sheet from the player menu; swipe-up now/next text; appearance staying in light mode after playback.

Client follow-ups pending server changes:
- If `/api/recordings/{id}/playback` starts returning `202 {status:"preparing"}` (recommended, P1-2), the client must poll — `RecordingPlayerModel.start()` currently treats anything but 200 as an error.
- Once the server populates `logo` from the EPG icon (P1-3), `BrowseModel.loadArtworkIndex()` and the `/api/proxy/epg/{id}` download can be removed from the client.

## 2. State of the server

Repo: github.com/maroge1990/PigTV, main at e73ee1f + the server agent's 0046 (bounded HLS disk usage) and 0047 (EPG parser mailbox) — Mark has applied both and reports instability on the Apple TV. No server patches were produced by this session.

Observations for the server agent about that instability:
- The deployed ffmpeg command in Mark's log shows `-hls_flags independent_segments+delete_segments`, but the 0046 source on the branch builds `['independent_segments','delete_segments','temp_file']` (`transcodeSession.js:470`). Either the running container is not the image built from 0046, or the flag list differs at runtime. Without `temp_file` the playlist is rewritten in place while segments are being deleted, and AVPlayer can read a truncated or inconsistent playlist — the most likely cause of stalls after a few minutes. First check: confirm the container is running the post-0046 image (`/api/version`, container image digest) and that `temp_file` is present in the logged command.
- Also check with `delete_segments`: AVPlayer on a live stream keeps a buffer behind the live edge and may re-request segments that fall out of a 90-segment window after a pause; `-hls_delete_threshold` (keep N extra segments beyond the list) is the standard mitigation.
- The software-decode retry path now calls `clearSegments()` on the live directory; a client mid-fetch sees files vanish. Prefer a fresh session directory or emit `#EXT-X-DISCONTINUITY`.
- `sweepOrphanedCache()` must run before any session is created at startup (verify ordering in `index.js`).
- 0047: confirm programme counts after a sync match the XMLTV (`SELECT COUNT(*) FROM epg_programs`) and that a recoverable parser warning no longer marks the sync failed.

Full review with file:line references: project doc `claude/server-review-2026-09-16.md`. Remaining items in priority order: P0-3 (auth on state-changing routes; accept bearer OR ?token= on `/api/playback/resolve`), P1-1 (viewer-vs-viewer arbitration, shorter live idle timeout), P1-2 (recording native playback: `-tag:v hvc1`, in-flight dedupe, temp-file rename, sidecar cleanup, 202 while preparing), P1-3 (favourites id normalisation + migration; EPG-icon logo fallback in `/api/library/*`), P1-4 (credential redaction), P1-5 (atomic EPG swap), P1-6 (drop `ffmpeg-static` require), P1-7 (cache db.json, drop express-session), then P2-1..P2-8.

Contract the Apple client depends on (do not change without a client update): see the "What the Apple client relies on" section of the review doc.

## 3. How fixes are delivered to Mark

Server changes: as `git format-patch` files, numbered continuing from 0048, applied with:

```powershell
cd "C:\Users\markr\OneDrive\Documents\GitHub\PassyTV"
git fetch origin
git checkout -B main origin/main
git am "$HOME\Downloads\patches\0048-<subject>.patch"
git push origin main
```

then on Unraid: pull the new `ghcr.io/maroge1990/pigtv` image, recreate the PigTV container (compose change in 0046 adds a tmpfs mount for `transcode-cache`, so a plain restart is not enough), and confirm `docker logs PigTV` shows the ffmpeg command with `temp_file` in `-hls_flags`.

Apple client changes: edited directly in the working Xcode project above; build from Xcode. No Git publication of the client has happened yet — recommend adding the `PigTV-Apple` folder to the repo (or its own repo) before further parallel work.

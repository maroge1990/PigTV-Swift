> Status update: The user has confirmed video playback working after server updates. The playback checks below are historical regression guidance, not an open diagnosis. Next priority: everyday usability, denser browsing, wider EPG and real channel artwork.

# PigTV client test checklist

Open the working project:
 /Users/markrogers/Documents/Codex/2026-09-13/i-ve/work/PigTV-Apple/PigTV.xcodeproj

Stop the previous run and build/run again. Saved pairing should remain. This build adds the native segmentedDelivery request flag.

## 1. Live playback — first priority
- With no other live playback or recording active, try the HEVC channel that previously failed.
- Server resolve should now choose an HLS session instead of /api/remux. It may call the strategy “transcode” while copying both video and audio; this does not itself mean an expensive encode.
- Check picture, sound, several minutes of continuous playback and returning to channels.
- Confirm the session is released, then try another channel.
- Repeat on a physical Apple TV when available.
- If it fails, capture the client’s route/error codes and the matching sanitized server log. Do not share URLs containing provider credentials or JWTs.
- If stream authentication is enabled, verify playlist, init segment and media segments all succeed, plus cleanup. Changing the setting is a separate deliberate server test.

## 2. Browse and remote navigation
- Move between Live TV, Guide, Favourites and Recordings.
- Select a channel: details should be opaque and readable; only Watch live should start playback.
- Search channels, choose categories, refresh and load additional pages.
- Check appearance using System, Light and Dark in Live TV → sidebar → Settings.
- Check long titles, missing programme information, focus visibility and Back.

## 3. Guide and schedules
- Move Earlier/Later/Now, select categories and load more channels.
- Open a current and future programme; verify description and local start/end times.
- Choose one intentional short test recording, review padding and confirm once.
- Verify it appears under Recordings → Scheduled and in the web app.
- Cancel that schedule and confirm the server status changes.
- Do not repeatedly submit after a timeout without checking the server; it may have accepted the first request.

## 4. Favourites
- Add one channel from its details, check the Favourites tab and web app.
- Remove it and refresh; verify it disappears.

## 5. Recordings
- Open existing recordings and check title, date, status, partial flag and available commercial-break times.
- Analysis requests run a real server job; use a completed recording you intentionally want analysed.
- Test Stop or Delete only on a recording you are willing to stop or permanently remove. Cancel each confirmation once first.
- Native recorded-video playback is not in this build; use the web app until its compatible media route is agreed.

## 6. One-stream conflicts
- With a recording running, attempt live playback: Keep recording must leave it intact.
- Explicitly choosing Stop recording and watch should only be tested when stopping it is acceptable.
- With live playback running, schedule a short test: confirm the recording prompt, Keep watching behavior, then stop playback and verify the server starts the waiting recording.
- Check the server if a waiting schedule disappears: older server code excludes waiting items from the scheduled list.

## Results to send back
Device/simulator, channel or recording name, steps, expected versus actual behavior, screenshot and sanitized error codes. The highest priority result is whether HLS playback now starts.

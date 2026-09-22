# PigTV client → server requests

Requests raised by the Apple client that must be actioned in the **server/webapp** repo
(`/Users/markrogers/Documents/GitHub/PigTV`), through its numbered-patch workflow. Each is
described by required user-visible behaviour, not an implementation. The client keeps any
interim workaround noted below until the server change ships; remove the workaround then.

Server disciplines still apply: **diagnose a playback fault from a capture of the real channel
before changing anything** (`scripts/stream-doctor.js`), gate ffmpeg/timestamp behaviour on the
probe (not a build number), and pair every functional patch with a `verify-build.sh` check and a
test that fails on the old code. Log the change in `docs/SWIFT-CLIENT-HANDOFF.md` §5.

---

## SR-1 — HDR channels are not flagged as HDR (P1)

**User-visible problem.** On an HDR channel (reported: Sky Sports Main Event UHD, HLG), the Apple
TV does not switch the display into HDR; the picture "looks very strange" (washed-out / wrong
tone). Confirmed on **both** the classic AVKit player and the new custom player, so it is **not**
the client video surface — the HLS stream is not carrying HDR signalling to AVFoundation.

**Required behaviour.** When the source channel is HDR (HLG or HDR10), the segments the client
receives must carry the colour signalling so tvOS reports the transfer function and switches the
panel to HDR: the fMP4 init segment's colour box (`colr`, `nclx`) must state the correct
**transfer characteristics** (HLG = `arib-std-b67`; HDR10 = `smpte2084`/PQ), **colour primaries**
(`bt2020`) and **matrix** (`bt2020nc`); for HDR10 also preserve the static **mastering-display**
and **MaxCLL/MaxFALL** side data. An SDR (BT.709) channel must be unchanged.

**Where it lives.** The HEVC copy path in `services/transcodeSession.js` (`-c:v copy`, fMP4,
`-tag:v hvc1`, around the `if (videoMode === 'copy')` block). On stream copy, ffmpeg only writes
`colr` if the colour properties reach the muxer; for some inputs they do not survive the
TS→fMP4 copy, so the init segment ends up SDR-tagged (or untagged) and AVFoundation stays in SDR.

**Suggested approach (verify against a capture first).**
1. Capture the channel with `stream-doctor.js` and `ffprobe -show_streams` the **source** for
   `color_transfer` / `color_primaries` / `color_space` — confirm it really is HLG/PQ + BT.2020.
2. `ffprobe` a **produced** init/segment for the same fields and inspect the `colr` box (e.g.
   `ffprobe -show_entries stream=color_transfer,color_primaries,color_space` and a `mp4dump`/
   `MP4Box -info` of `init.mp4`). If they are missing or wrong, that is the fault.
3. If copy drops them, set the colour metadata explicitly on the copy output, gated to feeds the
   probe classifies as HDR (mirror the existing `classifyTimestamps` gating pattern — add an HDR
   classification to `streamProbe` from the same cached probe, no extra provider connection):
   `-color_primaries bt2020 -color_trc arib-std-b67|smpte2084 -colorspace bt2020nc` (these are
   accepted on a copy path and are written into `colr`). Preserve HDR10 mastering-display / CLL
   side data where present. Do **not** apply to SDR feeds.
4. Confirm on the Apple TV that the panel flips to HDR and colour is correct; confirm an SDR
   channel is unchanged.

**Client side.** No client change needed or planned — the client renders whatever transfer
function the stream signals. Tracked as **R13** in the client blueprint.

---

## SR-2 — Strip the small-caps "ᴸɪᴠᴇ" badge from EPG titles and names (P2) — ✅ SHIPPED (server 0099)

**Shipped** in server build 0099: the badge is stripped at ingest from titles, sub-titles and
channel names in every response, using the same code-point ranges as the client stripper. The
client's `String.strippingBadgeSuffix` (DVRModels.swift) is now redundant but retained — remove it
once 0099 is confirmed deployed (double-stripping is a harmless no-op until then). Original request
below for reference.



**User-visible problem.** Programme titles and channel names arrive with a trailing small-capitals
badge, e.g. `NFL Football - Giants at Rams ᴸɪᴠᴇ` and `NFL 16 ᴸɪᴠᴇ`. It renders as a tacky
superscript. The characters are real Unicode modifier / small-capital letters in the provider's
EPG data (and channel names), not app styling.

**Required behaviour.** Titles, sub-titles and channel display names are presented without the
trailing decorative small-caps badge, for every client, from ingest.

**Where it lives.** `services/epgParser.js` — the `case 'title'`, `case 'sub-title'` and
`case 'display-name'` assignments (and wherever playlist/m3u channel names are ingested, if the
badge also appears there). Strip once at parse time so all clients and the webapp benefit.

**Suggested approach.** Trim a trailing run of code points in the phonetic/modifier-letter blocks
plus surrounding spaces — these never occur in ordinary English titles, so nothing legitimate is
removed:

```js
// Strips a trailing small-caps / modifier-letter badge (e.g. "ᴸɪᴠᴇ", "ɴᴇᴡ").
function stripBadgeSuffix(s) {
  if (!s) return s;
  // U+1D00–U+1DBF phonetic extensions, U+02B0–U+02FF modifier letters,
  // U+0250–U+02AF IPA extensions (small-cap forms), plus spaces.
  return s.replace(/[ᴀ-ᶿʰ-˿ɐ-ʯ\s]+$/u, '').trim();
}
```

Apply to `title`, `subtitle` and `name`. Pair with a test whose fixture title ends in the badge
and asserts it is gone (and that an ordinary title is untouched).

**Client side (interim).** The client already strips this at decode
(`String.strippingBadgeSuffix` in `DVRModels.swift`, covering programme titles and channel names)
so it is not blocking. Once the server strips at ingest, the client stripper becomes redundant and
can be removed. Tracked as **R15** in the client blueprint.

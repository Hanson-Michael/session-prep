# Session Prep

Part of the Music Production app series (after Music Production Budget). Native macOS app that gets a folder of audio files ready for a session: scans and reports every file's format/status, converts stereo files that are secretly mono (dual mono, panned mono, polarity-inverted mono, single-channel-silent) into true mono files, optionally levels/caps files toward safe working levels (Peak Safety and Leveling), and carries each file's broadcast/session metadata (BWF timecode, embedded tags) forward into every file it writes — all while leaving genuine stereo files' channel content untouched unless you deliberately opt them in.

## Platform & distribution

- macOS only (v1). Architecture keeps the analysis/conversion engine free of platform-specific UI code, so an iOS/iPadOS UI layer could be added later without rewriting the core logic.
- Direct download, notarized DMG — not Mac App Store. Distributed via GitHub Releases (same pattern as the Music Production Budget app).
- Auto-update via Sparkle (open source, MIT license, no cost) once the app is otherwise working. Feed: appcast.xml + EdDSA signing key, published alongside GitHub Releases. Deferred until core app is validated.

## What the app measures

The folder to scan is chosen via the **Select Folder…** button or by dragging onto the main window (an accent border highlights the window while something's being dragged over it). Both a dropped folder and dropped audio file(s) work — drop a folder and it's used directly; drop one or more files (e.g. dragged straight out of a session/export) and the source folder is inferred as the first file's containing folder, so you don't have to go find the folder yourself first. Dropping something unrelated is a no-op rather than guessing what was meant.

For every audio file in the selected top-level folder (no recursion into subfolders in v1 — flagged as a possible future toggle):

- Filename, file format/container
- Bit depth, sample rate, duration, file size
- Channel count
- Peak level, dBFS (per channel) — a plain per-sample scan, fast enough to run on every file during a folder scan. This is deliberately *not* True Peak: an earlier version measured True Peak (4x-oversampled) for every scanned file, which made large-folder scans noticeably slower for a number that only matters once you're actually about to convert a file. True Peak (see `Engine/TruePeakMeter.swift`) is now only computed at conversion time, feeding Peak Safety's gain decision — see below.
- RMS level, dBFS (per channel) — shown in its own column, separate from Peak
- Status (see classification below)

File format scope: primarily WAV/AIFF, but built to be open to whatever AVFoundation can decode (CAF, ALAC, FLAC, AAC/M4A, MP3) rather than hard-locking to two formats.

The table lists **every** audio file found, not just convertible ones — this is a full folder inventory/audit tool, not just a converter. Already-mono files and unreadable/corrupt files get their own status rather than being hidden. Already-Mono files still get real peak/RMS numbers (single-channel) rather than being left blank next to everyone else's measurements.

## Classification (stereo files only; mono files are simply "Already Mono")

Per stereo file, compute:
- `S = L + R` (sum, i.e. Mid) and `D = L − R` (difference, i.e. Side), sample-wise
- RMS and sample peak of L, R, S, and D — sample peak, not True Peak; see "What the app measures" above
- Cross-correlation coefficient between L and R (secondary/diagnostic signal, not the primary polarity test)

Classify in this order:

1. **Already Mono** — channel count = 1.
2. **No Audio Content** — both channels' peak below silence floor (default −80 dBFS).
3. **Silent Left/Right Channel** — one channel's peak below the silence floor, the other above it. Distinct icon from "No Audio Content" (a full "X" glyph is reserved for true full-file silence; a partial-silence icon marks a single dead channel within an otherwise live file).
4. **Polarity Inverted** — `S` (the sum) collapses to near-silence relative to the individual channel levels (the literal "L + R = 0" test), *and* both channels have sufficient level to trust the measurement (RMS above a noise-floor reliability gate, default −50 dBFS) — this rules out a spurious result from correlating near-empty noise. This is the authoritative test: it inherently requires both inverted polarity *and* matched levels, since only true opposite-and-equal signals cancel completely. Correlation ≤ −0.98 is used as a supporting/diagnostic check, tightened from the original −0.95 per review.
5. **Dual Mono** — `D` (the difference) collapses to near-silence (channels are essentially identical) and not already caught above.
6. **Panned Mono** — correlation between L and R is high (≥ 0.95, same waveform shape) but `D` does not collapse — same content, different channel gain.
7. **True Stereo** — everything else. Default/safe bucket.
8. **Needs Review** — borderline zone that doesn't cleanly clear a threshold (correlation between −0.90 and −0.98 for the inversion boundary, or between 0.90 and 0.95 for the dual/panned-mono boundary). Never auto-classified into an actionable bucket; flagged for manual inspection instead of guessed at.
9. **Error** — file couldn't be read/decoded.

All thresholds above are v1 defaults, adjustable later based on real-file testing (Settings window has editable thresholds).

## Conversion rules

Never sum L+R to produce the new mono file — that's only safe for Dual Mono, and actively wrong (cancels to near-silence) for Polarity Inverted, and level-distorting for Panned Mono. Every fixable case is resolved by **selecting** one channel:

| Status | New mono file source |
|---|---|
| Dual Mono | Either channel (identical) |
| Panned Mono | The louder channel, as-is (no gain matching in v1) |
| Polarity Inverted | Auto-picked by comparing per-channel noise floor (cleaner-sounding channel wins) |
| Silent Left/Right Channel | The non-silent channel |
| True Stereo | Not touched by default — Leave As Is / Peak Safety / Split to L/R, see below |
| Already Mono | Not touched by default — Leave As Is / Peak Safety, see below |
| No Audio / Needs Review / Error | Never actionable — no Action column choice at all |

### Action column options for True Stereo and Already Mono

Both of these are opt-in only, chosen per file via the Action column's dropdown — nothing about a True Stereo or Already Mono file is ever written or moved without a deliberate choice on that row. Leave As Is is always the default.

- **True Stereo**: Leave As Is / Peak Safety / Split to L/R.
  - **Split to L/R** — for a file that's *genuinely* stereo but you want the channels apart as two discrete mono files anyway. Produces two new mono files, suffixed literally `.L` and `.R` (e.g. `Vocal.L.wav`, `Vocal.R.wav`), both from the same original — this suffix is structural (it's the only thing keeping the two output files distinct) and stays on even if the descriptive-suffix toggle is off.
  - **Peak Safety** — writes a new *stereo* file (same L/R balance, channel count unchanged, no split) with the Peak Safety/Leveling gain pass applied — see below. For measuring that gain on a two-channel file: peak is the hotter of the two channels' True Peak (so neither channel can end up past the ceiling), RMS is the average of the two channels' RMS (a stand-in for overall loudness without a full LUFS measurement). The same resulting gain is applied uniformly to both channels, so the stereo image never shifts.
- **Already Mono**: Leave As Is / Peak Safety. Same gain pass as above, just measured on the file's one channel directly (no averaging needed) and written back out as mono.

Both write a **new** file, following the exact same Original/New folder rules as every other conversion (see Output organization) — never an in-place overwrite. If the computed gain works out to exactly 1.0 (the file's already within whatever limits are enabled), **nothing is written and the original isn't moved** — a mostly-already-fine batch doesn't get filled with byte-for-byte duplicates.

### Output organization

Where files actually land is a **per-run choice**, made in the pre-flight review sheet that opens when you click **Process Selected…** (see Process Selected review sheet, below) — not a fixed convention baked into the app. Each option list is ordered least- to most-committal (Leave in place → custom folder → the named default), with the named default pre-selected:

- **Original files**: Leave in place · Move to a custom folder you choose · Move to `Source - Stereo/` (default). Files never touched by a conversion/split are never affected by this, regardless of choice.
- **New mono/split files**: Leave in place (written directly into the folder being scanned, no subfolder) · A custom folder you choose · Move to `Processed - Mono/` (default).
- **Filenames**: by default, a suffix is appended so a glance at the filename tells you what happened and whether it's worth double-checking:
  - `_mono` — Dual Mono (both channels were identical; nothing to verify)
  - `_mono-pan-L` / `_mono-pan-R` — Panned Mono, channel kept
  - `_mono-inv-L` / `_mono-inv-R` — Polarity Inverted, channel auto-picked (worth spot-checking — this one's a judgment call)
  - `_mono-sc-L` / `_mono-sc-R` — Silent-channel file, channel kept
  - `.L` / `.R` — deliberate True Stereo split (two files, not one — always applied, not affected by the suffix toggle)

  A toggle in the review sheet ("Add suffixes") can turn the descriptive suffixes above off (new files then just reuse the original filename); `.L`/`.R` for splits is unaffected either way.

Both `Source - Stereo/` and `Processed - Mono/` are flat, top-level only in v1 (matches no-recursion scope) when using the default locations.

### Broadcast/session metadata preservation

`AVAudioFile`'s writer only knows about the audio-format chunks themselves (`fmt `/`data` in a WAV, `COMM`/`SSND` in an AIFF) — left alone, every conversion or split would silently drop anything else a source file carries, most critically a WAV's BWF `bext` chunk (whose `TimeReference` field is what lets a DAW auto-place a file at its correct absolute position on a timeline — losing it defeats the point of using this app in a real session workflow). `Engine/BroadcastMetadata.swift` fixes this: every chunk from the source *other than* the ones the writer regenerates — `bext`, `iXML` (field-recorder metadata), cue/marker chunks, `LIST`/`INFO` tags (title/artist/album/comment), an embedded `id3 ` chunk, AIFF's NAME/AUTH/annotation/copyright chunks, anything else — is read as a raw, unparsed blob and spliced into the newly-written file. `bext` specifically is reinserted as the very first chunk (BWF spec requirement); everything else is appended after the writer's own chunks. Since a converted/split file starts at the exact same sample position as its source, copying this data verbatim (including `TimeReference`) is always correct — nothing in it needs adjusting.

MP3 sources are a special case: `AVAudioFile` can decode MP3 but can't encode it, so a converted/split MP3 already falls back to a WAV output regardless of this feature. Since ID3 (MP3's tag format) and RIFF chunks are unrelated binary structures, the WAV-chunk logic above wouldn't recognize an ID3 tag — instead, the source's raw ID3v2 tag block is read and dropped, unparsed, into the new WAV as a standard `id3 ` chunk, carrying Title/Artist/Album/etc. forward the same way.

Best-effort throughout: a source or destination that isn't well-formed RIFF/WAV or FORM/AIFF simply yields nothing to preserve — this never blocks or fails an actual conversion, it just means that one file won't carry extra metadata forward (same as if this didn't exist at all).

### Peak Safety & Leveling (both attenuate-only, both True Peak/RMS based)

Two independent gain mechanisms, neither of which is loudness normalization — "Peak Safety" replaced an earlier "Normalize" label specifically because that implied the wrong kind of processing. **Both only ever lower a file's level, never raise it.** Leveling isn't gated by Peak Safety or vice versa — either can be on by itself.

- **Peak Safety** — default **off**. Ceiling **−4 dBTP**, measured against a dedicated True Peak scan run at conversion time (not the table's Peak column, which is plain sample peak for fast scanning — see "What the app measures" above).
- **Leveling** — default **off**. Target **−14 dBFS** (RMS), measured against a dedicated RMS scan run at conversion time (not the table's RMS column, same reasoning as Peak Safety). Files whose average level is already at or under the target are left alone; hotter ones get pulled down to it.
- Both are standing preferences (persisted, editable in Settings → Output), and both are also surfaced in the Process Selected review sheet so they're visible/adjustable right before a run without a trip to Settings first. The Settings and review-sheet controls edit the same underlying values.
- **Combined behavior**: each computes its own required cut independently (Peak Safety: `ceiling − current peak`; Leveling: `target − current RMS`, only when the file is hotter than each respective target), and whichever one wants the *bigger* cut is what actually gets applied. Since neither can ever raise gain — each is individually capped at a no-op (1.0×) — this can never leave a file peaking hotter than Peak Safety's ceiling, even with both on and Leveling wanting a large boost-equivalent correction on an otherwise-quiet-but-hot-peaked file: the peak constraint always wins in that conflict. See `MonoConverter.combinedGain`.
- Purpose: correction for overly hot recorded levels on files being touched (gives headroom to reprocess/un-clip later, and keeps individual stems from summing hot once combined in a mix), not a loudness-matching tool. Applies automatically (no extra opt-in) to every auto-fix conversion and True Stereo split output, and optionally to Already Mono / un-split True Stereo files via the Action column's Peak Safety option — see above. Does not apply to any file left as Leave As Is.

## Table controls

- Column order: checkbox · Action · Status · Filename · Format · Bit Depth · Sample Rate · Duration · Peak L/R · RMS L/R · Size. Checkbox and Action sit together up front — the two things you *set* — followed by Status and Filename, the two things you read to know what a row is. Format/Bit Depth/Sample Rate/Duration/Peak/RMS/Size are secondary technical detail, pushed to the tail end.
- A checkbox alone sits left of the Action column header — no label, since a checkbox in a table header is self-explanatory. Toggles all auto-fix rows at once. Never touches True Stereo or Already Mono rows; those stay an individual, deliberate per-row choice. (SwiftUI's `Table` can't accept a custom view inside its own native header cell on macOS 13, so this is an overlay positioned directly on top of that column's blank header cell — an earlier version rendered it as a separate strip stacked above the table, which read as a floating extra row rather than sitting inline with "Filename"/"Format"/etc.)
- Every row has a leading checkbox: auto-fix rows bind to their inclusion flag; Already Mono rows bind to the *same* value as their Action-column dropdown (checking the box and choosing "Peak Safety" are the same switch); True Stereo rows reflect "not Leave As Is" — since the Action dropdown there has three states a plain checkbox can't fully capture, checking it from idle defaults to Split to L/R (the dropdown is where you reach for Peak Safety specifically); anything not actionable shows a dash. The header "select all" checkbox still only sets the auto-fix rows — it never opts a True Stereo or Already Mono row in on your behalf, it just reflects/counts whatever's already been individually marked.
- The **Action** column shows what will happen to each row: a fixed description for auto-fix rows (nothing to choose), a three-way Leave As Is/Peak Safety/Split to L/R dropdown for True Stereo rows, a two-way Leave As Is/Peak Safety dropdown for Already Mono rows, and a dash for anything not actionable (silence, Needs Review, Error).
- The bottom-bar button is **Process Selected…** (not "Convert Selected to Mono") — the ellipsis signals it opens the review sheet below rather than running immediately; a batch run can include mono conversions, True Stereo splits, and Peak Safety-only files together.

## Process Selected review sheet

Clicking **Process Selected…** doesn't run anything immediately — it opens a review sheet that surfaces every choice affecting the run in one place, rather than having them split across the bottom bar and Settings:

- A one-line summary: how many files will be converted, split, and (if any are opted in) how many are queued for Peak Safety only.
- **Original Files**: Leave in place · Move to a custom folder · Move to `Source - Stereo/` (default).
- **New Mono Files**: Write to source folder (no subfolder) · Move to a custom folder · Move to `Processed - Mono/` (default).
- **Peak Safety**: same toggle + ceiling as Settings → Output (shared value, edits either place). Label is careful to say "lower level," not "cap" — this isn't a limiter touching dynamics, it's a one-time gain reduction applied before writing the file if its peak exceeds the ceiling.
- **Leveling**: same toggle + RMS target as Settings → Output, same shared-value relationship. Independent of Peak Safety — either can be on alone; see "Peak Safety & Leveling" above for how they combine when both are on.
- A toggle for descriptive filename suffixes ("Add suffixes," on by default) — see Output organization above. Its caption doesn't change with the toggle state, both to avoid resizing the sheet and because the toggle's own label already says what it does.
- Each option list uses custom radio rows rather than SwiftUI's native radio-group Picker, specifically so the custom-folder path + Choose… row can sit directly under "Move to a custom folder…" itself instead of trailing after the whole group (which read as belonging to whatever option was listed last). That row is always laid out, just enabled/disabled based on the selection, so nothing resizes as you click between options.
- Cancel / Process buttons. Process is disabled until there's at least one file to act on and any chosen custom folder has actually been picked.

These are **per-run choices** — the sheet always opens back at the safe defaults (move to the named subfolder, suffixes on) rather than remembering the last run's choices, so a one-off custom folder pick doesn't quietly become the new default.

## Revert / undo

None in v1. Originals are always preserved (moved, never deleted), so recovery is a manual Finder move if ever needed. Not worth the added complexity given the safety net already in place.

## Menu structure

**Session Prep** (app menu): About Session Prep · Settings… (⌘,) · Services · Hide Session Prep (⌘H) · Hide Others (⌥⌘H) · Show All · Quit Session Prep (⌘Q)

**File**: Open Folder… (⌘O)

**Help**: Check for Updates… · Automatically Check for Updates (checkbox)

## Visual design

- Main working window: new, clean, crisp look — not a reuse of the Budget app's exact chrome, but keeps the same color palette (vs. plain white).
- About window and update-progress window: **kept consistent** with the Budget app for series branding — including the "Communicating with aliens…" radar-ping animation treatment. Same idea reused for Session Prep's own scan/convert progress indicator, not just app updates.
- Color palette carried over: light background `#fdfcf8`, dark background `#2b2a28`, accent `#4a90d9`, track `#e3e0d8` (light) / `#4a4844` (dark).

## Channel preview playback

A real transport, not click-to-play buttons — sits at the top of the window (below the folder bar), always rendered in the same layout whether or not anything's loaded (disabled/grayed rather than replaced by a placeholder, so nothing jumps around). Selecting a single stereo *or mono* row loads the whole file into memory once; switching modes, seeking, and playing are then all instant and never re-read from disk. Mono files are fully auditionable too, not just stereo — anything the table lists, you can hear. For a mono file the mode picker is replaced by a static "Mono — single channel" label (only one meaningful way to play it) rather than showing five modes that would all sound identical.

Controls: Play/Pause, Stop, a five-way mode picker (stereo files) or the static mono label, and a scrub bar with elapsed/total time. Play/Pause also responds to the spacebar, matching the typical transport convention. Modes: **L ‖ R** (unmodified stereo — a baseline "hear it as it actually sounds" reference), **L**, **R**, **L + R** (should collapse toward silence for a genuine Polarity Inverted file), **L − R** (should collapse toward silence for a genuine Dual Mono file). Mode can be switched live, mid-playback, continuing from the same position rather than requiring Stop first.

**Engine (`Engine/AudioPreviewPlayer.swift`)**: plays the raw L/R samples continuously through a single `AVAudioSourceNode`, computing each output sample live in its render callback as `out = matrix * in`, where `matrix` is a small 2x2 mix that differs per mode (e.g. L+R mode is `[[0.5, 0.5], [0.5, 0.5]]`). A mode switch never restarts or re-anchors playback — it just ramps the matrix's four coefficients toward the new mode's values over ~35ms, entirely within the one continuous signal, so there's nothing to overlap and no position to lose track of. This replaced two earlier approaches that both kept clicking or skipping: a single pre-rendered buffer per mode (hard cutover on switch), then a two-node buffer crossfade (which overlapped two independently rendered copies of the *same* correlated audio and produced an audible phasing/gurgling artifact, plus still restarted the read position on every switch). Seeking is the one case that still needs an actual jump in the source — it fades out over ~15ms, jumps the read position, and fades back in, timed sample-accurately inside the render callback rather than via a wall-clock timer. Play/Pause/Stop use the same short fade. Plays the whole file, not a capped snippet.

## Explicitly out of scope for v1

- Recursive subfolder scanning (flagged as a future toggle)
- In-app revert/undo
- Mac App Store distribution
- Gain-matching/normalization as part of Panned Mono conversion (louder channel is kept as-is)

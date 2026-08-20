# IngestIQ

See `SPEC.md` for the full design spec (classification logic, thresholds, folder/suffix scheme, menu structure, distribution plan).

## Opening this in Xcode

The real app lives in **`Session Prep.xcodeproj`** — open that (not `Package.swift`) to build and run:

1. Open `Session Prep.xcodeproj` in Xcode.
2. Pick the **Session Prep** scheme and "My Mac" as the destination.
3. Hit **Run** (⌘R).

The Xcode project already has code signing, App Sandbox (with User Selected File — Read/Write), and its own generated Info.plist wired in via build settings — no separate setup step needed.

`Package.swift` and `Sources/SessionPrep/` are a secondary, reference-only mirror of the same source kept in sync for diffing purposes; they aren't part of the shipped app and don't need to be opened to build or run it.

## Known things worth a second look

- **`MonoConverter.writeMonoFile`** — the buffer format handed to `AVAudioFile.write(from:)` has to exactly match the file's internal `processingFormat`; if a format-mismatch error ever shows up, that's the spot to check.
- **`BroadcastMetadata`** — chunk-preservation logic for BWF (`bext`), embedded ID3, and other WAV/AIFF metadata chunks. If a DAW ever fails to pick up a file's original timecode or tags after conversion, start here.

If anything doesn't compile or behaves oddly, paste the error or describe it and it'll get fixed directly.

## Updates

Sparkle is wired in — `UpdateChecker.swift` owns an `SPUStandardUpdaterController`, the feed is `appcast.xml` at the repo root (served raw via GitHub), and the app runs unsandboxed to allow the network access and self-replacement Sparkle's install step needs. See `RELEASING.md` for the full cut-a-release checklist (versioning, notarization, signing, and updating the appcast).

## Deliberately not in this pass

- Recursive subfolder scanning.
- In-app revert/undo.

## Try it

1. Run the app.
2. **File > Open Folder…**, pick a folder with a mix of mono/stereo WAV or AIFF files.
3. Check the classifications against what you'd expect, then try converting a couple.
4. Tell me what's wrong and we'll fix it from there.

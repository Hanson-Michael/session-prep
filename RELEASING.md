# Releasing IngestIQ

## Quick path

Bump **Version** and **Build** in Xcode's target **General** tab to the same
new value (must increase every release — see step 1 below for why), then run:

```
Scripts/release.sh
```

That's it — it archives, exports, zips, notarizes, staples, signs for
Sparkle, publishes the GitHub Release, writes the appcast.xml entry, and
pushes, pausing only to ask for optional release notes. One-time setup it
assumes is already done: GitHub CLI installed and authenticated
(`brew install gh && gh auth login`), notarization credentials stored
(`session-prep-notary` profile), and the Sparkle signing key generated.

The manual steps below are the same process broken out one command at a
time — useful for understanding what the script does, or for debugging if
a step fails (e.g. notarization coming back `Invalid`).

## Manual steps

> **Naming note:** Version and Build are the same number (see step 1) —
> `YY.MM.Dxx`, e.g. `26.8.140` for the first release on August 14, `26.8.141`
> for a second release that same day. Because the day+sequence tail is part
> of the version itself, every release already gets a unique tag/filename
> with no separate suffix to remember. The examples below use a single
> version for brevity; substitute accordingly.

Repeatable steps for shipping a new version through Sparkle. Reference values
for this project:

- Bundle ID: `com.mlhproductions.SessionPrep`
- Team ID: `9MP82ALK4M`
- Notary keychain profile: `session-prep-notary`
- GitHub repo: `Hanson-Michael/session-prep`
- Appcast feed (tracked in repo, served raw): `https://raw.githubusercontent.com/Hanson-Michael/session-prep/main/appcast.xml`

## 1. Bump the version

In Xcode, select the **Session Prep** target → **General** tab (or **Build
Settings**), and set **Version** and **Build** to the *same* value —
`YY.MM.Dxx`: two-digit year, month, then day-of-month immediately followed by
a sequence digit for same-day re-releases (`0` for the first release that
day, `1` for the second, and so on). E.g. `26.8.140` for the first release on
August 14, 2026; `26.8.141` for a second release that same day; `26.9.10` for
the first release on September 1.

- **Version** (`MARKETING_VERSION`) — the human-facing version shown in
  Finder/About. This is `sparkle:shortVersionString` in the appcast.
- **Build** (`CURRENT_PROJECT_VERSION`) — this is `sparkle:version` in the
  appcast, what Sparkle actually compares to decide if an update is newer.
  Because year/month lead the number, a later month always compares newer
  than an earlier one regardless of the day/sequence tail (e.g. `26.9.10` >
  `26.8.141`), so the calendar scheme sorts correctly on its own — the only
  discipline required is bumping the trailing sequence digit for a same-day
  re-release, exactly like any other version bump.

Keep the two fields identical. `Scripts/release.sh` verifies this and refuses
to run if they've drifted apart.

## 2. Archive and export a Developer ID build

1. **Product → Archive** in Xcode.
2. In the Organizer window that opens, select the new archive → **Distribute App**.
3. Choose **Direct Distribution** (sometimes labeled **Developer ID**) — not
   App Store Connect.
4. Let Xcode sign it with your Developer ID Application certificate and
   export the `.app`. Note the export folder path.

## 3. Zip it

```
cd /path/to/export/folder
ditto -c -k --keepParent "IngestIQ.app" "IngestIQ-26.8.140.zip"
```

`ditto` (not Finder's "Compress") preserves the code signature correctly.

## 4. Notarize

```
xcrun notarytool submit "IngestIQ-26.8.140.zip" --keychain-profile "session-prep-notary" --wait
```

Wait for `status: Accepted`. If it says `Invalid`, run:

```
xcrun notarytool log <submission-id> --keychain-profile "session-prep-notary"
```

to see why, and fix before continuing.

## 5. Staple the ticket

Unzip, staple the `.app` itself (not the zip), then re-zip for distribution:

```
unzip "IngestIQ-26.8.140.zip" -d staple-tmp
xcrun stapler staple "staple-tmp/IngestIQ.app"
ditto -c -k --keepParent "staple-tmp/IngestIQ.app" "IngestIQ-26.8.140.zip"
rm -rf staple-tmp
```

This final `IngestIQ-26.8.140.zip` is the one that gets uploaded and
referenced in the appcast — it lets the app verify and launch offline without
hitting Apple's servers.

## 6. Sign the release zip for Sparkle

Find `sign_update` the same way `generate_keys` was found earlier:

```
find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1
```

Run it against the final zip:

```
/path/to/sign_update "IngestIQ-26.8.140.zip"
```

It prints an `sparkle:edSignature="..."` value and a `length="..."` value —
copy both, you'll need them in step 8. This reads the private key
automatically from your login Keychain (from the `generate_keys` step), so
nothing else to pass in.

## 7. Publish the release on GitHub

1. github.com/Hanson-Michael/session-prep → **Releases** → **Draft a new release**.
2. Tag: `v26.8.140` (match the version — Version and Build are the same now,
   so there's no separate build suffix to append).
3. Upload `IngestIQ-26.8.140.zip` as a release asset.
4. Publish.
5. Copy the asset's download URL — right-click the uploaded file link, or
   it follows the pattern:
   `https://github.com/Hanson-Michael/session-prep/releases/download/v26.8.140/IngestIQ-26.8.140.zip`

## 8. Add the appcast entry

Edit `appcast.xml` at the repo root — add a new `<item>` **above** any
existing ones (Sparkle takes the first item as latest), filling in the
values from steps 1, 6, and 7:

```xml
<item>
    <title>Version 26.8.140</title>
    <sparkle:version>26.8.140</sparkle:version>
    <sparkle:shortVersionString>26.8.140</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
        <ul>
            <li>What changed in this release.</li>
        </ul>
    ]]></description>
    <pubDate>Thu, 13 Aug 2026 00:00:00 +0000</pubDate>
    <enclosure
        url="https://github.com/Hanson-Michael/session-prep/releases/download/v26.8.140/IngestIQ-26.8.140.zip"
        sparkle:edSignature="KU/GTMs2tBM4wmb7SYzSOtjAE7rsLqtKPzifNBUVmD8FJptLaPSbte6LY4zPQ2ZeHH2qD3D9zttv5WFRaN6HCQ=="
        length="11054174"
        type="application/octet-stream" />
</item>
```

`sparkle:version` and `sparkle:shortVersionString` are the same value now —
both come from step 1's unified Version/Build number.

## 9. Push

```
cd "/Users/michaelhanson/Documents/Xcode/Session Prep"
git add appcast.xml
git commit -m "Release 26.8.140"
git push
```

## 10. Verify

Run an older build of the app, **Help → Check for Updates…**, confirm it
finds 26.8.140, downloads, and installs correctly.

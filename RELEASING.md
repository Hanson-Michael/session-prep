# Releasing Session Prep

## Quick path

Bump **Version** and **Build** in Xcode's target **General** tab (Build must
increase every release — see step 1 below for why), then run:

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

> **Naming note:** if you're publishing more than once in the same month
> (same marketing Version), the tag and zip filename must still be unique —
> append the build number, e.g. `v26.8-2` / `SessionPrep-26.8-2.zip`, not
> just `v26.8` again. The examples below use a single version for brevity;
> substitute accordingly.

Repeatable steps for shipping a new version through Sparkle. Reference values
for this project:

- Bundle ID: `com.mlhproductions.SessionPrep`
- Team ID: `9MP82ALK4M`
- Notary keychain profile: `session-prep-notary`
- GitHub repo: `Hanson-Michael/session-prep`
- Appcast feed (tracked in repo, served raw): `https://raw.githubusercontent.com/Hanson-Michael/session-prep/main/appcast.xml`

## 1. Bump the version

In Xcode, select the **Session Prep** target → **General** tab (or **Build
Settings**):

- **Version** (`MARKETING_VERSION`) — the human-facing version, e.g. `26.8`.
  This is `sparkle:shortVersionString` in the appcast.
- **Build** (`CURRENT_PROJECT_VERSION`) — bump by at least 1 every release,
  even for the same marketing version. This is `sparkle:version` in the
  appcast — it's what Sparkle actually compares to decide if an update is
  newer, not the marketing string.

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
ditto -c -k --keepParent "Session Prep.app" "SessionPrep-26.8.zip"
```

`ditto` (not Finder's "Compress") preserves the code signature correctly.

## 4. Notarize

```
xcrun notarytool submit "SessionPrep-26.8.zip" --keychain-profile "session-prep-notary" --wait
```

Wait for `status: Accepted`. If it says `Invalid`, run:

```
xcrun notarytool log <submission-id> --keychain-profile "session-prep-notary"
```

to see why, and fix before continuing.

## 5. Staple the ticket

Unzip, staple the `.app` itself (not the zip), then re-zip for distribution:

```
unzip "SessionPrep-26.8.zip" -d staple-tmp
xcrun stapler staple "staple-tmp/Session Prep.app"
ditto -c -k --keepParent "staple-tmp/Session Prep.app" "SessionPrep-26.8.zip"
rm -rf staple-tmp
```

This final `SessionPrep-26.8.zip` is the one that gets uploaded and referenced
in the appcast — it lets the app verify and launch offline without hitting
Apple's servers.

## 6. Sign the release zip for Sparkle

Find `sign_update` the same way `generate_keys` was found earlier:

```
find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1
```

Run it against the final zip:

```
/path/to/sign_update "SessionPrep-26.8.zip"
```

It prints an `sparkle:edSignature="..."` value and a `length="..."` value —
copy both, you'll need them in step 8. This reads the private key
automatically from your login Keychain (from the `generate_keys` step), so
nothing else to pass in.

## 7. Publish the release on GitHub

1. github.com/Hanson-Michael/session-prep → **Releases** → **Draft a new release**.
2. Tag: `v26.8` (match the marketing version).
3. Upload `SessionPrep-26.8.zip` as a release asset.
4. Publish.
5. Copy the asset's download URL — right-click the uploaded file link, or
   it follows the pattern:
   `https://github.com/Hanson-Michael/session-prep/releases/download/v26.8/SessionPrep-26.8.zip`

## 8. Add the appcast entry

Edit `appcast.xml` at the repo root — add a new `<item>` **above** any
existing ones (Sparkle takes the first item as latest), filling in the
values from steps 1, 6, and 7:

```xml
<item>
    <title>Version 26.8</title>
    <sparkle:version>1</sparkle:version>
    <sparkle:shortVersionString>26.8</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
        <ul>
            <li>What changed in this release.</li>
        </ul>
    ]]></description>
    <pubDate>Thu, 13 Aug 2026 00:00:00 +0000</pubDate>
    <enclosure
        url="https://github.com/Hanson-Michael/session-prep/releases/download/v26.8/SessionPrep-26.8.zip"
        sparkle:edSignature="KU/GTMs2tBM4wmb7SYzSOtjAE7rsLqtKPzifNBUVmD8FJptLaPSbte6LY4zPQ2ZeHH2qD3D9zttv5WFRaN6HCQ=="
        length="11054174"
        type="application/octet-stream" />
</item>
```

`sparkle:version` = the `CURRENT_PROJECT_VERSION` build number from step 1,
not the marketing version.

## 9. Push

```
cd "/Users/michaelhanson/Documents/Xcode/Session Prep"
git add appcast.xml
git commit -m "Release 26.8"
git push
```

## 10. Verify

Run an older build of the app, **Help → Check for Updates…**, confirm it
finds 26.8, downloads, and installs correctly.

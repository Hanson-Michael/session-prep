# Releasing Session Prep

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

- **Version** (`MARKETING_VERSION`) — the human-facing version, e.g. `1.1`.
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
ditto -c -k --keepParent "Session Prep.app" "SessionPrep-1.1.zip"
```

`ditto` (not Finder's "Compress") preserves the code signature correctly.

## 4. Notarize

```
xcrun notarytool submit "SessionPrep-1.1.zip" --keychain-profile "session-prep-notary" --wait
```

Wait for `status: Accepted`. If it says `Invalid`, run:

```
xcrun notarytool log <submission-id> --keychain-profile "session-prep-notary"
```

to see why, and fix before continuing.

## 5. Staple the ticket

Unzip, staple the `.app` itself (not the zip), then re-zip for distribution:

```
unzip "SessionPrep-1.1.zip" -d staple-tmp
xcrun stapler staple "staple-tmp/Session Prep.app"
ditto -c -k --keepParent "staple-tmp/Session Prep.app" "SessionPrep-1.1.zip"
rm -rf staple-tmp
```

This final `SessionPrep-1.1.zip` is the one that gets uploaded and referenced
in the appcast — it lets the app verify and launch offline without hitting
Apple's servers.

## 6. Sign the release zip for Sparkle

Find `sign_update` the same way `generate_keys` was found earlier:

```
find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1
```

Run it against the final zip:

```
/path/to/sign_update "SessionPrep-1.1.zip"
```

It prints an `sparkle:edSignature="..."` value and a `length="..."` value —
copy both, you'll need them in step 8. This reads the private key
automatically from your login Keychain (from the `generate_keys` step), so
nothing else to pass in.

## 7. Publish the release on GitHub

1. github.com/Hanson-Michael/session-prep → **Releases** → **Draft a new release**.
2. Tag: `v1.1` (match the marketing version).
3. Upload `SessionPrep-1.1.zip` as a release asset.
4. Publish.
5. Copy the asset's download URL — right-click the uploaded file link, or
   it follows the pattern:
   `https://github.com/Hanson-Michael/session-prep/releases/download/v1.1/SessionPrep-1.1.zip`

## 8. Add the appcast entry

Edit `appcast.xml` at the repo root — add a new `<item>` **above** any
existing ones (Sparkle takes the first item as latest), filling in the
values from steps 1, 6, and 7:

```xml
<item>
    <title>Version 1.1</title>
    <sparkle:version>131</sparkle:version>
    <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
        <ul>
            <li>What changed in this release.</li>
        </ul>
    ]]></description>
    <pubDate>Thu, 13 Aug 2026 00:00:00 +0000</pubDate>
    <enclosure
        url="https://github.com/Hanson-Michael/session-prep/releases/download/v1.1/SessionPrep-1.1.zip"
        sparkle:edSignature="PASTE_FROM_sign_update"
        length="PASTE_FROM_sign_update"
        type="application/octet-stream" />
</item>
```

`sparkle:version` = the `CURRENT_PROJECT_VERSION` build number from step 1,
not the marketing version.

## 9. Push

```
cd "/Users/michaelhanson/Documents/Xcode/Session Prep"
git add appcast.xml
git commit -m "Release 1.1"
git push
```

## 10. Verify

Run an older build of the app, **Help → Check for Updates…**, confirm it
finds 1.1, downloads, and installs correctly.

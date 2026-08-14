#!/usr/bin/env bash
#
# End-to-end release script for Session Prep. Reads the version/build
# straight from the Xcode project (bump those in Xcode's General tab
# *before* running this), then archives, exports, zips, notarizes, staples,
# signs for Sparkle, publishes a GitHub Release, writes the appcast.xml
# entry, and pushes. See RELEASING.md for the manual version of every step
# here, useful if something in this script needs debugging.
#
# Prerequisites (one-time):
#   - GitHub CLI installed and authenticated: brew install gh && gh auth login
#   - Notarization credentials stored: xcrun notarytool store-credentials
#     "session-prep-notary" (already done)
#   - Sparkle signing key generated (already done — lives in Keychain)
#
# Usage: Scripts/release.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Session Prep.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"
SCHEME="Session Prep"
BUNDLE_NAME="Session Prep"
GITHUB_REPO="Hanson-Michael/session-prep"
NOTARY_PROFILE="session-prep-notary"
EXPORT_OPTIONS="$REPO_ROOT/Scripts/ExportOptions.plist"
BUILD_DIR="$REPO_ROOT/.release-build"
ARCHIVE_PATH="$BUILD_DIR/SessionPrep.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

log() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
die() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Read version info straight from the project -------------------------

VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/')
MIN_OS=$(grep -m1 'MACOSX_DEPLOYMENT_TARGET = ' "$PBXPROJ" | sed -E 's/.*MACOSX_DEPLOYMENT_TARGET = ([^;]+);.*/\1/')
ZIP_NAME="SessionPrep-${VERSION}.zip"
TAG="v${VERSION}"

[[ -n "$VERSION" && -n "$BUILD" ]] || die "Could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.pbxproj."

log "Release plan"
echo "  Version (marketing): $VERSION"
echo "  Build (Sparkle compares this): $BUILD"
echo "  Tag: $TAG"
echo "  Zip: $ZIP_NAME"
read -r -p "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# --- Prerequisite checks ---------------------------------------------------

command -v gh >/dev/null 2>&1 || die "GitHub CLI not found. Install with: brew install gh, then: gh auth login"
gh auth status >/dev/null 2>&1 || die "gh is installed but not authenticated. Run: gh auth login"

# --- Archive ---------------------------------------------------------------

log "Archiving (this can take a minute)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    | tail -20

# --- Export a Developer ID build -------------------------------------------

log "Exporting Developer ID build"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | tail -20

cd "$EXPORT_PATH"
[[ -d "$BUNDLE_NAME.app" ]] || die "Export didn't produce $BUNDLE_NAME.app — check the xcodebuild output above."

# --- Zip, notarize, staple, re-zip -----------------------------------------

log "Zipping for notarization"
ditto -c -k --keepParent "$BUNDLE_NAME.app" "$ZIP_NAME"

log "Submitting for notarization (waiting on Apple — can take a few minutes)"
NOTARY_OUTPUT=$(xcrun notarytool submit "$ZIP_NAME" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$NOTARY_OUTPUT"
echo "$NOTARY_OUTPUT" | grep -q "status: Accepted" || die "Notarization did not return Accepted — see log above. Run 'xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\"' for details."

log "Stapling ticket and re-zipping for distribution"
xcrun stapler staple "$BUNDLE_NAME.app"
rm -f "$ZIP_NAME"
ditto -c -k --keepParent "$BUNDLE_NAME.app" "$ZIP_NAME"

# --- Sign for Sparkle --------------------------------------------------------

log "Signing release zip for Sparkle"
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1)
[[ -n "$SIGN_UPDATE" ]] || die "Could not find sign_update in DerivedData — build the project in Xcode at least once first."
SIGN_OUTPUT=$("$SIGN_UPDATE" "$ZIP_NAME")
echo "$SIGN_OUTPUT"
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | sed -E 's/sparkle:edSignature="([^"]+)"/\1/')
LENGTH=$(echo "$SIGN_OUTPUT" | grep -oE 'length="[0-9]+"' | sed -E 's/length="([0-9]+)"/\1/')
[[ -n "$ED_SIGNATURE" && -n "$LENGTH" ]] || die "Couldn't parse edSignature/length from sign_update output above."

# --- Release notes -----------------------------------------------------------

log "Release notes (optional)"
echo "Enter one bullet per line. Blank line to finish (just press Enter to skip entirely):"
NOTES_LINES=()
while IFS= read -r line; do
    [[ -z "$line" ]] && break
    NOTES_LINES+=("$line")
done

GH_NOTES=""
APPCAST_ITEMS=""
if [[ ${#NOTES_LINES[@]} -eq 0 ]]; then
    APPCAST_ITEMS="                    <li>Minor updates.</li>"$'\n'
    GH_NOTES="Minor updates."
else
    for line in "${NOTES_LINES[@]}"; do
        GH_NOTES+="- ${line}"$'\n'
        APPCAST_ITEMS+="                    <li>${line}</li>"$'\n'
    done
fi

# --- Publish the GitHub Release ---------------------------------------------

log "Publishing GitHub Release $TAG"
gh release create "$TAG" "$ZIP_NAME" \
    --repo "$GITHUB_REPO" \
    --title "$VERSION" \
    --notes "$GH_NOTES" \
    --target main

ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${ZIP_NAME}"

# --- Write the appcast entry -------------------------------------------------

log "Updating appcast.xml"
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
ITEM_FILE="$BUILD_DIR/item.xml"

cat > "$ITEM_FILE" <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <ul>
${APPCAST_ITEMS}                </ul>
            ]]></description>
            <pubDate>${PUB_DATE}</pubDate>
            <enclosure
                url="${ASSET_URL}"
                sparkle:edSignature="${ED_SIGNATURE}"
                length="${LENGTH}"
                type="application/octet-stream" />
        </item>
EOF

python3 <<PYEOF
appcast_path = "$REPO_ROOT/appcast.xml"
item_path = "$ITEM_FILE"
with open(appcast_path) as f:
    content = f.read()
with open(item_path) as f:
    item = f.read()
marker = "<language>en</language>"
idx = content.index(marker) + len(marker)
content = content[:idx] + "\n\n" + item + content[idx:]
with open(appcast_path, "w") as f:
    f.write(content)
PYEOF

# --- Commit and push ---------------------------------------------------------

log "Committing and pushing appcast.xml"
cd "$REPO_ROOT"
git add appcast.xml
git commit -m "Release ${VERSION}"
git push

rm -rf "$BUILD_DIR"

log "Done"
echo "Released ${VERSION} (build ${BUILD}) — https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo "Remember to bump the Version/Build numbers in Xcode before the next release."

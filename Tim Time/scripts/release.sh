#!/usr/bin/env bash
# One-shot TimTime release: archive → notarize → staple → DMG → sign for Sparkle.
# Usage: ./scripts/release.sh [version]    (e.g. ./scripts/release.sh 1.1.0)
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
NOTARY_PROFILE="${NOTARY_PROFILE:-TimTime-Notary}"   # set via `xcrun notarytool store-credentials`
SCHEME="Tim Time"
APP_NAME="Tim Time"
BUNDLE_ID="AI-Ascend.Tim-Time"
PROJECT_NAME="Tim Time"

# ── Paths ───────────────────────────────────────────────────────────────────
cd "$(dirname "$0")/.."
BUILD=build
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/$APP_NAME.app"
ZIP="$BUILD/$APP_NAME.zip"
DMG="$BUILD/TimTime.dmg"

# ── Pretty print ────────────────────────────────────────────────────────────
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ── Prereqs ─────────────────────────────────────────────────────────────────
bold "→ Checking prerequisites"
command -v create-dmg >/dev/null || die "create-dmg not installed (brew install create-dmg)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "Notary profile '$NOTARY_PROFILE' not in Keychain. Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id YOU@example.com --team-id 6B42ZYWPK4 --password APP-SPECIFIC-PASSWORD"
CERT_LINE=$(security find-identity -p codesigning -v | grep "Developer ID Application" | head -1)
[ -n "$CERT_LINE" ] || die "No 'Developer ID Application' cert. Add in Xcode → Settings → Accounts → Manage Certificates."
TEAM_ID=$(echo "$CERT_LINE" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')
[ -n "$TEAM_ID" ] || die "Could not parse team ID from cert: $CERT_LINE"
ok "All tools and credentials present (team $TEAM_ID)"

# ── Optional version bump ───────────────────────────────────────────────────
# Updates MARKETING_VERSION in the .pbxproj. Build number auto-increments.
if [ "${1:-}" != "" ]; then
    NEW_VERSION="$1"
    bold "→ Bumping version to $NEW_VERSION"
    /usr/bin/sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $NEW_VERSION/g" \
        "$PROJECT_NAME.xcodeproj/project.pbxproj"
    CURRENT_BUILD=$(/usr/bin/sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' \
        "$PROJECT_NAME.xcodeproj/project.pbxproj" | head -1)
    NEW_BUILD=$((CURRENT_BUILD + 1))
    /usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $NEW_BUILD/g" \
        "$PROJECT_NAME.xcodeproj/project.pbxproj"
    ok "Version $NEW_VERSION (build $NEW_BUILD)"
fi
VERSION=$(/usr/bin/sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' \
    "$PROJECT_NAME.xcodeproj/project.pbxproj" | head -1)
BUILD_NUM=$(/usr/bin/sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' \
    "$PROJECT_NAME.xcodeproj/project.pbxproj" | head -1)

# ── Clean ───────────────────────────────────────────────────────────────────
rm -rf "$BUILD"
mkdir -p "$BUILD"

# ── Archive ─────────────────────────────────────────────────────────────────
bold "→ Archiving Release build (v$VERSION build $BUILD_NUM)"
xcodebuild -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination "generic/platform=macOS" \
    archive \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    -quiet
ok "Archive built"

# ── Export ──────────────────────────────────────────────────────────────────
bold "→ Exporting signed .app"
EXPORT_OPTS="$BUILD/ExportOptions.plist"
cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$EXPORT_OPTS" \
    -quiet
[ -d "$APP" ] || die "Expected $APP after export — not found"
ok "Exported to $APP"

# ── Notarize ────────────────────────────────────────────────────────────────
bold "→ Notarizing with Apple (this can take 1–5 minutes)"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
SUBMIT_OUT=$(xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json)
echo "$SUBMIT_OUT" | python3 -m json.tool
STATUS=$(echo "$SUBMIT_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
if [ "$STATUS" != "Accepted" ]; then
    SUBMIT_ID=$(echo "$SUBMIT_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    warn "Notarization status: $STATUS — fetching log…"
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE"
    die "Notarization failed"
fi
ok "Apple accepted the build"

# ── Staple ──────────────────────────────────────────────────────────────────
bold "→ Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ok "Stapled"

# ── DMG ─────────────────────────────────────────────────────────────────────
bold "→ Packaging DMG"
rm -f "$DMG"
create-dmg \
    --volname "TimTime" \
    --window-size 540 360 \
    --background scripts/dmg-background.png \
    --icon-size 100 \
    --icon "$APP_NAME.app" 140 180 \
    --app-drop-link 400 180 \
    "$DMG" \
    "$APP" >/dev/null
ok "DMG at $DMG ($(du -h "$DMG" | cut -f1))"

# ── Sparkle EdDSA signature ─────────────────────────────────────────────────
# Locate sign_update from the Sparkle SwiftPM artifacts. Path varies by
# Xcode + project name; we walk DerivedData looking for it.
bold "→ Signing DMG for Sparkle appcast"
SIGN_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -name "sign_update" 2>/dev/null | head -1)
if [ -z "$SIGN_BIN" ]; then
    warn "sign_update not found — Sparkle SwiftPM dep not added yet?"
    warn "Once added, build the project once in Xcode; sign_update will appear in DerivedData."
    warn "Skipping appcast signature."
else
    SIG_LINE=$("$SIGN_BIN" "$DMG")
    ok "Signed"
    echo
    bold "Appcast entry — paste into appcast.xml:"
    cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$(date -u +"%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD_NUM</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="REPLACE_WITH_DMG_URL"
                $SIG_LINE
                type="application/octet-stream" />
        </item>
EOF
fi

echo
bold "Done. Version $VERSION (build $BUILD_NUM) shipped to $DMG"
echo "  Next: upload \`$DMG\` to GitHub Releases, paste the <item> block into appcast.xml."

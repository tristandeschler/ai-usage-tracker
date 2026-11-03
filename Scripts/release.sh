#!/bin/bash
# Builds a Developer ID-signed, notarized and stapled Token Tracker, zipped for release.
# Notarization goes through the Apple account Xcode is signed in to (Xcode → Settings → Accounts).
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build/release
ARCHIVE="$BUILD/TokenTracker.xcarchive"
rm -rf "$BUILD"
mkdir -p "$BUILD"

xcodegen generate >/dev/null
VERSION=$(xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION =/ { print $3; exit }')
echo "Archiving Token Tracker ${VERSION}…"
xcodebuild archive -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Release \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet

echo "Signing with Developer ID and submitting for notarization…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist Scripts/ExportOptions.plist \
    -exportPath "$BUILD/submitted" -allowProvisioningUpdates -quiet

echo "Waiting for Apple to notarize (usually a few minutes)…"
for attempt in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$BUILD/notarized" -quiet >/dev/null 2>&1; then
        break
    fi
    [ "$attempt" = 60 ] && { echo "Notarization didn't finish in 30 minutes." >&2; exit 1; }
    sleep 30
done

APP="$BUILD/notarized/Token Tracker.app"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"

ZIP="$BUILD/TokenTracker-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Done: $ZIP"

# PUBLISH=1 make release: create the GitHub release the in-app updater looks for.
if [ "${PUBLISH:-0}" = 1 ]; then
    REPO=$(xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -showBuildSettings 2>/dev/null | awk '/ TT_UPDATE_REPOSITORY =/ { print $3; exit }')
    gh release create "v${VERSION}" "$ZIP" "$ZIP.sha256" --repo "$REPO" --target main \
        --title "Token Tracker ${VERSION}" --notes "SHA-256 of $(basename "$ZIP"): $(cut -d' ' -f1 "$ZIP.sha256")"
    echo "Published v${VERSION} to ${REPO}"
fi

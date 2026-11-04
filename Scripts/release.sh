#!/bin/bash
# Builds a Developer ID-signed, notarized and stapled Token Tracker, zipped for release.
# Signing and notarization go through the Apple account Xcode is signed in to.
#
#   PUBLISH=1   publish the zip as a GitHub release (what the in-app updater looks for)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build/release
ARCHIVE="$BUILD/TokenTracker.xcarchive"

xcodegen generate >/dev/null
setting() {
    xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -showBuildSettings 2>/dev/null |
        awk -v name="$1" '$1 == name && $2 == "=" { print $3; exit }'
}
VERSION=$(setting MARKETING_VERSION)
REPO=$(setting TT_UPDATE_REPOSITORY)

# Published builds must be exactly what's on main, and catching a problem here saves a long wait.
if [ "${PUBLISH:-0}" = 1 ]; then
    git fetch -q origin main
    [ -z "$(git status --porcelain)" ] || { echo "Commit or discard your changes first." >&2; exit 1; }
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Check out the latest main first." >&2; exit 1; }
    if gh release view "v${VERSION}" --repo "$REPO" >/dev/null 2>&1; then
        echo "v${VERSION} is already released. Bump MARKETING_VERSION in project.yml first." >&2
        exit 1
    fi
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "Archiving Token Tracker ${VERSION}…"
xcodebuild archive -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet

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

if [ "${PUBLISH:-0}" = 1 ]; then
    gh release create "v${VERSION}" "$ZIP" "$ZIP.sha256" --repo "$REPO" --target "$(git rev-parse HEAD)" \
        --title "Token Tracker ${VERSION}" \
        --notes "SHA-256 of $(basename "$ZIP"): \`$(cut -d' ' -f1 "$ZIP.sha256")\`"
    echo "Published v${VERSION} to ${REPO}"
fi

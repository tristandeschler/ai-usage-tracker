#!/bin/bash
# Builds a Developer ID-signed, notarized and stapled Token Tracker, zipped for release.
#
# Locally, signing and notarization go through the Apple account Xcode is signed in to.
# In CI, set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (an App Store Connect API key) instead.
#
#   VERSION=1.2.3   build as this version instead of MARKETING_VERSION from project.yml
#   PUBLISH=1       publish the zip as a GitHub release (what the in-app updater looks for)
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build/release
ARCHIVE="$BUILD/TokenTracker.xcarchive"
rm -rf "$BUILD"
mkdir -p "$BUILD"

AUTH=()
ARCHIVE_SETTINGS=()
EXPORT_OPTIONS=Scripts/ExportOptions.plist

xcodegen generate >/dev/null
setting() {
    xcodebuild -project TokenTracker.xcodeproj -scheme TokenTrackerMac -showBuildSettings 2>/dev/null |
        awk -v name="$1" '$1 == name && $2 == "=" { print $3; exit }'
}

if [ -n "${ASC_KEY_PATH:-}" ]; then
    AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    # CI machines aren't registered devices, so they can't get a development profile. Archive
    # unsigned instead; the entitlements are added back ad hoc below for the export to re-sign.
    TEAM=$(setting DEVELOPMENT_TEAM)
    BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)
    ARCHIVE_SETTINGS=(CODE_SIGNING_ALLOWED=NO AppIdentifierPrefix="$TEAM." TeamIdentifierPrefix="$TEAM.")
    EXPORT_OPTIONS="$BUILD/ExportOptions.plist"
    cp Scripts/ExportOptions.plist "$EXPORT_OPTIONS"
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM" "$EXPORT_OPTIONS"
fi

# Signs a bundle ad hoc with its entitlements file, filling in the build variables it uses.
adhoc_sign() {
    local resolved="$BUILD/$(basename "$2")"
    sed -e "s/\$(TT_APP_GROUP)/$TEAM.$BUNDLE_ID/" \
        -e "s/\$(AppIdentifierPrefix)\$(PRODUCT_BUNDLE_IDENTIFIER)/$TEAM.$BUNDLE_ID/" "$2" > "$resolved"
    codesign --force --sign - --entitlements "$resolved" "$1"
}

if [ -n "${VERSION:-}" ]; then
    ARCHIVE_SETTINGS+=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)")
else
    VERSION=$(setting MARKETING_VERSION)
fi

echo "Archiving Token Tracker ${VERSION}…"
xcodebuild archive -project TokenTracker.xcodeproj -scheme TokenTrackerMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
    ${ARCHIVE_SETTINGS[@]+"${ARCHIVE_SETTINGS[@]}"} -quiet

if [ -n "${ASC_KEY_PATH:-}" ]; then
    ARCHIVED_APP="$ARCHIVE/Products/Applications/Token Tracker.app"
    adhoc_sign "$ARCHIVED_APP/Contents/PlugIns/TokenTrackerWidget.appex" Apps/Widget/TokenTrackerWidget.entitlements
    adhoc_sign "$ARCHIVED_APP" Apps/Mac/TokenTracker.entitlements
fi

echo "Signing with Developer ID and submitting for notarization…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$BUILD/submitted" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet

echo "Waiting for Apple to notarize (usually a few minutes)…"
for attempt in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$BUILD/notarized" ${AUTH[@]+"${AUTH[@]}"} -quiet >/dev/null 2>&1; then
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
    REPO=$(setting TT_UPDATE_REPOSITORY)
    NOTES="${RELEASE_NOTES:-}"
    gh release create "v${VERSION}" "$ZIP" "$ZIP.sha256" --repo "$REPO" --target "$(git rev-parse HEAD)" \
        --title "Token Tracker ${VERSION}" \
        --notes "${NOTES}${NOTES:+

}SHA-256 of $(basename "$ZIP"): \`$(cut -d' ' -f1 "$ZIP.sha256")\`"
    echo "Published v${VERSION} to ${REPO}"
fi

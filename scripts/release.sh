#!/bin/bash
# Builds a signed, notarized PairMagic DMG for distribution outside the App Store.
#
#   scripts/release.sh
#
# Output: build/release/PairMagic-<version>.dmg
#
# One-time setup (see README › Releasing):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials saved under the profile name below:
#        xcrun notarytool store-credentials PairMagic-Notary --apple-id <you@example.com> --team-id B4H429V95D
#
# Environment overrides:
#   SIGNING_IDENTITY    codesign identity (default: "Developer ID Application")
#   NOTARY_PROFILE      notarytool keychain profile (default: PairMagic-Notary)
#   NOTARY_KEYCHAIN     keychain holding the notary profile (default: the keychain search list)
#   VERSION             version to build, e.g. 1.0.1 (default: MARKETING_VERSION in the project)
#   BUILD_NUMBER        build number to use with VERSION (default: CURRENT_PROJECT_VERSION)
#   SKIP_NOTARIZATION=1 sign and package only, e.g. to test the script locally
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PairMagic"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-PairMagic-Notary}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
[ -n "${NOTARY_KEYCHAIN:-}" ] && NOTARY_AUTH+=(--keychain "$NOTARY_KEYCHAIN")
OUT="build/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# MARK: Preflight

step "Checking prerequisites"
security find-identity -v -p codesigning | grep -q "\"$SIGNING_IDENTITY" \
    || fail "No \"$SIGNING_IDENTITY\" certificate in your keychain. Create one at developer.apple.com › Certificates (type: Developer ID Application), or see README › Releasing."
if [ "$SKIP_NOTARIZATION" != 1 ]; then
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 \
        || fail "No notary credentials saved as \"$NOTARY_PROFILE\". Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id B4H429V95D"
fi

VERSION_SETTINGS=()
if [ -n "${VERSION:-}" ]; then
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "VERSION must look like 1.2.3, not \"$VERSION\""
    VERSION_SETTINGS+=(MARKETING_VERSION="$VERSION")
    if [ -n "${BUILD_NUMBER:-}" ]; then
        [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER must be a whole number, not \"$BUILD_NUMBER\""
        VERSION_SETTINGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
    fi
else
    VERSION=$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release -showBuildSettings 2>/dev/null \
        | awk '/ MARKETING_VERSION = / { print $3; exit }')
    [ -n "$VERSION" ] || fail "Couldn't read MARKETING_VERSION"
fi
DMG="$OUT/$APP_NAME-$VERSION.dmg"
echo "Version $VERSION${BUILD_NUMBER:+ ($BUILD_NUMBER)}, signing as \"$SIGNING_IDENTITY\""

rm -rf "$OUT"
mkdir -p "$OUT"

# MARK: Build and sign

step "Archiving"
xcodebuild archive -quiet \
    -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"}

APP="$OUT/$APP_NAME.app"
ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# (Captured first: with pipefail, `grep -q` exiting early would fail the pipe.)
signature=$(codesign -d --verbose=2 "$APP" 2>&1)
[[ "$signature" == *"(runtime)"* ]] || fail "Hardened runtime isn't enabled"
entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
[[ "$entitlements" != *"get-task-allow"* ]] || fail "Release build has the debugging entitlement"

# MARK: Notarize the app

notarize() {
    xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --output-format json \
        | tee "$OUT/notary.json" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("Notarization:", r["status"]); sys.exit(r["status"] != "Accepted")' \
        || { id=$(python3 -c 'import json; print(json.load(open("'"$OUT"'/notary.json"))["id"])'); \
             xcrun notarytool log "$id" "${NOTARY_AUTH[@]}"; fail "Notarization failed (log above)"; }
}

if [ "$SKIP_NOTARIZATION" != 1 ]; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
    notarize "$OUT/$APP_NAME.zip"
    rm "$OUT/$APP_NAME.zip"
    # Stapling lets it pass Gatekeeper offline too.
    xcrun stapler staple "$APP"
fi

# MARK: Package

step "Building the DMG"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARIZATION" != 1 ]; then
    step "Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    step "Checking Gatekeeper"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
fi

rm -f "$OUT/notary.json"
step "Done"
echo "$DMG"
[ "$SKIP_NOTARIZATION" = 1 ] && echo "(not notarized: SKIP_NOTARIZATION=1, so other Macs will block it)"
exit 0

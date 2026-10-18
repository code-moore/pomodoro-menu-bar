#!/usr/bin/env bash
# Builds the Mac App Store flavour and packages it for upload.
#
# It differs from ./build.sh (the direct-download build) in what the store
# requires: sandboxed, no Sparkle (the store does the updating and rejects
# apps that bring their own updater), its own bundle ID, a compiled icon and
# a privacy manifest. The result is a .pkg in dist/AppStore/ to upload with
# Transporter or Xcode's Organizer.
#
#   TEAM_ID=YOUR_TEAM_ID ./build-appstore.sh
#   TEAM_ID=YOUR_TEAM_ID PROFILE=~/Downloads/Pomodoro_Mac_App_Store.provisionprofile ./build-appstore.sh
#
# Settings below can be overridden from the environment. The bundle ID is
# permanent once an App Store Connect record uses it, so confirm it then.
set -euo pipefail
cd "$(dirname "$0")"
[ ! -f .signing.local.sh ] || source ./.signing.local.sh

BUNDLE_ID="${BUNDLE_ID:-com.codemoore.pomodoro.menubar}"
TEAM_ID="${TEAM_ID:-}"
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'ERROR: Set TEAM_ID to your 10-character Apple Developer team ID (A-Z and 0-9),' >&2
  echo '       or configure .signing.local.sh from signing.example.sh.' >&2
  echo '       Find it in your developer account under Membership details.' >&2
  exit 1
fi
APP_NAME="Pomodoro"
COPYRIGHT="${COPYRIGHT:-© 2026 Michael Moore}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
# Must go up with every upload of the same version. Date then time keeps it
# rising, and keeps each part well inside the 32-bit range App Store Connect
# expects; a single 14-digit timestamp like build.sh's would not be.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d).$((10#$(date +%H%M)))}"
PROFILE="${PROFILE:-}"

OUT_DIR="dist/AppStore"
APP="$OUT_DIR/$APP_NAME.app"
PKG="$OUT_DIR/$APP_NAME-$VERSION-$BUILD_NUMBER.pkg"

# --- 1. Build without Sparkle -------------------------------------------------
# APP_STORE=1 is read by Package.swift. The separate scratch path stops SwiftPM
# reusing the manifest it evaluated for the regular build.
export APP_STORE=1
export CLANG_MODULE_CACHE_PATH="$PWD/.build-appstore/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-appstore/swiftpm-module-cache"
SPM_FLAGS=(
  -c release --arch arm64 --arch x86_64
  --cache-path "$PWD/.build/cache"
  --config-path "$PWD/.build/config"
  --security-path "$PWD/.build/security"
  --scratch-path "$PWD/.build-appstore"
  # Nested sandboxing is blocked inside the harness sandbox; see build.sh.
  --disable-sandbox
)

echo "==> swift build (App Store flavour, arm64 + x86_64)"
swift build "${SPM_FLAGS[@]}"
BIN_PATH="$(swift build "${SPM_FLAGS[@]}" --show-bin-path)/$APP_NAME"

# --- 2. Assemble the bundle ---------------------------------------------------
mkdir -p "$OUT_DIR"
if [ -e "$APP" ]; then
  # Only ever this script's own output.
  rm -r "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Set :CFBundleIdentifier $BUNDLE_ID"
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :CFBundleVersion $BUILD_NUMBER"
# Sparkle's settings mean nothing here, and reviewers look for them.
for key in SUEnableAutomaticChecks SUFeedURL SUPublicEDKey; do
  pb "Delete :$key" 2>/dev/null || true
done
pb "Add :LSApplicationCategoryType string public.app-category.productivity"
# Uses no encryption beyond what macOS provides, so no export paperwork.
pb "Add :ITSAppUsesNonExemptEncryption bool false"
pb "Add :NSHumanReadableCopyright string $COPYRIGHT"

echo "==> Compiling the app icon"
actool_out="$(mktemp -d)"
xcrun actool Resources/AppIcon.icon \
  --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$actool_out/icon.plist" \
  --output-format human-readable-text >/dev/null
pb "Add :CFBundleIconFile string AppIcon"
pb "Add :CFBundleIconName string AppIcon"

cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"

# --- 3. Entitlements and provisioning profile ---------------------------------
ENTITLEMENTS="$actool_out/app.entitlements"
cp Resources/AppStore.entitlements "$ENTITLEMENTS"
if [ -n "$PROFILE" ]; then
  echo "==> Embedding provisioning profile"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  # Uploads need these, and they must match the profile. Without a profile they
  # stop the app launching, so they are only added here.
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"
fi

# --- 4. Sign ------------------------------------------------------------------
find_identity() {  # first identity whose name starts with one of the prefixes
  local policy="$1"; shift
  local listing
  listing="$(security find-identity -v $policy 2>/dev/null || true)"
  for prefix in "$@"; do
    local match
    match="$(printf '%s\n' "$listing" | sed -n "s/.*\"\($prefix[^\"]*($TEAM_ID)\)\".*/\1/p" | head -1)"
    if [ -n "$match" ]; then echo "$match"; return; fi
  done
}

UPLOADABLE=1
APP_IDENTITY="${APP_IDENTITY:-$(find_identity "-p codesigning" "Apple Distribution: " "3rd Party Mac Developer Application: ")}"
if [ -z "$APP_IDENTITY" ]; then
  UPLOADABLE=0
  APP_IDENTITY="$(find_identity "-p codesigning" "Developer ID Application: ")"
  echo "==> WARNING: no App Store signing certificate (Apple Distribution) found."
  echo "    Signing with '$APP_IDENTITY' for a LOCAL SANDBOX TEST ONLY;"
  echo "    App Store Connect will not accept this build."
fi
[ -n "$PROFILE" ] || UPLOADABLE=0

echo "==> Signing with: $APP_IDENTITY"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
  --sign "$APP_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# --- 5. Check what the store will check ----------------------------------------
echo "==> Checking the bundle"
problems=0
if find "$APP" -iname '*sparkle*' | grep -q .; then
  echo "    FAIL: a Sparkle file is in the bundle"; problems=1
fi
if otool -L "$APP/Contents/MacOS/$APP_NAME" | grep -qi sparkle; then
  echo "    FAIL: the binary links Sparkle"; problems=1
fi
if grep -q '<key>SU' "$PLIST"; then
  echo "    FAIL: Sparkle keys left in Info.plist"; problems=1
fi
signed_entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
for key in com.apple.security.app-sandbox com.apple.security.personal-information.calendars; do
  if ! grep -q "$key" <<<"$signed_entitlements"; then
    echo "    FAIL: entitlement $key missing"; problems=1
  fi
done
[ "$problems" = 0 ] && echo "    no Sparkle, sandboxed, calendar entitlement present"
[ "$problems" = 0 ] || exit 1

# --- 6. Package -----------------------------------------------------------------
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(find_identity "" "3rd Party Mac Developer Installer: " "Mac Installer Distribution: ")}"
if [ -n "$INSTALLER_IDENTITY" ]; then
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
else
  UPLOADABLE=0
  productbuild --component "$APP" /Applications "$PKG"
  echo "==> WARNING: no installer certificate (3rd Party Mac Developer Installer);"
  echo "    the package is unsigned and can't be uploaded."
fi

echo
echo "==> Built $APP"
echo "    bundle ID $BUNDLE_ID, version $VERSION ($BUILD_NUMBER)"
echo "==> Packaged $PKG"
if [ "$UPLOADABLE" = 1 ]; then
  echo "    Ready to upload: open Transporter, sign in, and drag the .pkg in."
else
  echo "    Not uploadable yet. See docs/app-store-release.md for the certificates"
  echo "    and provisioning profile to create, then run this again with PROFILE=..."
fi

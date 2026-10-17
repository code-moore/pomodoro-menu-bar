#!/usr/bin/env bash
# Builds Pomodoro.app — a real double-clickable bundle — from the SwiftPM target.
set -euo pipefail
cd "$(dirname "$0")"
[ ! -f .signing.local.sh ] || source ./.signing.local.sh

CONFIG="${1:-release}"
APP="${APP_OUTPUT:-Pomodoro.app}"
APP_NAME="Pomodoro"
RELEASE_BUILD="${RELEASE_BUILD:-0}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.codemoore.pomodoro.menubar}"

# Where Sparkle looks for the update feed. Override per release:
#   APPCAST_URL=https://your.site/appcast.xml ./build.sh
APPCAST_URL="${APPCAST_URL:-$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist)}"

# A running instance keeps the OLD executable and Info.plist in memory, and
# `open` will merely focus it rather than launching the new bundle — so a
# rebuild would silently appear to do nothing. Quit first, relaunch after.
WAS_RUNNING=0
if [ "$APP" = "Pomodoro.app" ] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "==> Quitting the running instance (it would otherwise stay stale)"
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in $(seq 1 25); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

# Keep every cache inside the project. swiftc otherwise writes its module cache
# to $TMPDIR/C/clang/ModuleCache, which fails under a restricted sandbox.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache"

SPM_CACHE_FLAGS=(
  --cache-path "$PWD/.build/cache"
  --config-path "$PWD/.build/config"
  --security-path "$PWD/.build/security"
  --scratch-path "$PWD/.build"
  # SwiftPM normally wraps each compile in `sandbox-exec`. Nested sandboxing is
  # blocked inside the harness sandbox. Drop this line for a normal terminal.
  --disable-sandbox
)

# Universal binary so Intel Macs can run it too.
ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "==> swift build -c $CONFIG (arm64 + x86_64)"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${SPM_CACHE_FLAGS[@]}"

BIN_PATH="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" "${SPM_CACHE_FLAGS[@]}" --show-bin-path)/Pomodoro"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH" "$APP/Contents/MacOS/Pomodoro"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# Reuse the icon and privacy manifest already used by the App Store build.
ICON_TEMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TEMP"' EXIT
xcrun actool Resources/AppIcon.icon \
  --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICON_TEMP/icon.plist" \
  --output-format human-readable-text >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP/Contents/Info.plist"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"

# --- Embed Sparkle -----------------------------------------------------------
# SwiftPM links the XCFramework but does not bundle it. The framework has to be
# copied into the app and located via the @executable_path/../Frameworks rpath
# declared in Package.swift.
SPARKLE_FW="$(find .build/artifacts/sparkle -maxdepth 4 -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FW" ]; then
  echo "ERROR: Sparkle.framework not found under .build/artifacts." >&2
  echo "       Run: swift package resolve" >&2
  exit 1
fi

echo "==> Embedding Sparkle.framework"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# --- Update feed settings ----------------------------------------------------
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$APP/Contents/Info.plist"

# The public half of the update signing key. Prefer the local key file written
# by ./setup-sparkle-key.sh; fall back to Sparkle's Keychain lookup.
#
# Note: `generate_keys -p` prints its error to *stdout* when no key exists, so
# the shape is validated before use — otherwise the error text ends up embedded
# as the key.
SPARKLE_PUBKEY=""
if [ -f sparkle_public_key.txt ]; then
  SPARKLE_PUBKEY="$(tr -d '[:space:]' < sparkle_public_key.txt)"
else
  GEN_KEYS="$(find .build/artifacts/sparkle -type f -name generate_keys 2>/dev/null | head -1)"
  if [ -n "$GEN_KEYS" ]; then
    SPARKLE_PUBKEY="$("$GEN_KEYS" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)"
  fi
fi

if [[ "$SPARKLE_PUBKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBKEY" "$APP/Contents/Info.plist"
  echo "==> Sparkle public key installed"
else
  if [ "$RELEASE_BUILD" = 1 ]; then
    echo "ERROR: a release requires a valid Sparkle public key." >&2
    exit 1
  fi
  # Leave the key empty: Sparkle then refuses to install updates rather than
  # trying to verify against garbage.
  echo "==> WARNING: no Sparkle update signing key — auto-update will be inert."
  echo "    Create one with:  ./setup-sparkle-key.sh"
fi

# --- Sign --------------------------------------------------------------------
# A *stable* identity matters twice over:
#   1. TCC binds the calendar permission to the code signature, so an ad-hoc
#      signature means macOS re-prompts after every single rebuild.
#   2. Sparkle requires the running app and the update to share a signing
#      identity before it will install anything.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

sign() {
  # Optional second argument: an entitlements file. Only the app itself gets
  # one; the Sparkle pieces inside it keep their own.
  local entitlements=()
  [ -n "${2:-}" ] && entitlements=(--entitlements "$2")
  # Timestamping needs Apple's server; fall back to a plain hardened signature
  # if it is unreachable (it is required for notarization, not for local use).
  if [ "$RELEASE_BUILD" = 1 ]; then
    codesign --force --options runtime --timestamp ${entitlements[@]+"${entitlements[@]}"} --sign "$SIGN_IDENTITY" "$1"
  else
    codesign --force --options runtime --timestamp ${entitlements[@]+"${entitlements[@]}"} --sign "$SIGN_IDENTITY" "$1" 2>/dev/null \
      || codesign --force --options runtime ${entitlements[@]+"${entitlements[@]}"} --sign "$SIGN_IDENTITY" "$1"
  fi
}

if [ "$RELEASE_BUILD" = 1 ] && [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "ERROR: releases require a Developer ID Application identity." >&2
  exit 1
fi

if [ -n "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  echo "==> Signing with: $SIGN_IDENTITY"

  FW="$APP/Contents/Frameworks/Sparkle.framework"
  V="$FW/Versions/B"

  # Inside-out: nested code must be signed before whatever contains it,
  # otherwise the outer signature is invalidated by the inner one.
  if [ -d "$V/XPCServices" ]; then
    for xpc in "$V"/XPCServices/*.xpc; do
      [ -e "$xpc" ] || continue
      sign "$xpc"
    done
  fi
  [ -e "$V/Updater.app" ] && sign "$V/Updater.app"
  [ -e "$V/Autoupdate" ] && sign "$V/Autoupdate"
  sign "$FW"
  # Hardened runtime blocks calendar access unless the entitlement is signed in.
  sign "$APP" Resources/Pomodoro.entitlements
else
  if [ "$RELEASE_BUILD" = 1 ]; then
    echo "ERROR: release signing identity not found: $SIGN_IDENTITY" >&2
    exit 1
  fi
  echo "==> WARNING: signing identity not found; falling back to ad-hoc."
  echo "    Set SIGN_IDENTITY or configure .signing.local.sh for a stable signature."
  echo "    Calendar access will be re-requested after every rebuild."
  codesign --force --deep --entitlements Resources/Pomodoro.entitlements --sign - "$APP"
fi

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo "==> Built $APP"

if [ "$WAS_RUNNING" = "1" ]; then
  echo "==> Relaunching the new build"
  open "$APP"
else
  echo "    open $APP"
fi

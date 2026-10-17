#!/usr/bin/env bash
# Build a notarized website download and a verified Sparkle appcast.
# ./release.sh --check   checks credentials and signing before building
# ./release.sh 1.2       writes publishable files to releases/
set -euo pipefail
cd "$(dirname "$0")"
[ ! -f .signing.local.sh ] || source ./.signing.local.sh

VERSION="${1:-}"
if [[ "$VERSION" != --check && ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo 'usage: ./release.sh <version> | --check' >&2
  exit 1
fi
if [ "${NOTARIZE:-1}" != 1 ]; then
  echo 'ERROR: website releases must be notarized. Use ./build.sh for local testing.' >&2
  exit 1
fi

APP="dist/Direct/Pomodoro.app"
RELEASES="releases"
NOTARY_PROFILE="${NOTARY_PROFILE:-pomodoro}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.codemoore.pomodoro.menubar}"
APPCAST_URL="${APPCAST_URL:-$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist)}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-${APPCAST_URL%/*}/}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
PYTHON="${PYTHON:-/usr/bin/python3}"
export APPCAST_URL SIGN_IDENTITY SPARKLE_ACCOUNT

# Fail before changing a bundle or source file.
"$PYTHON" - "$APPCAST_URL" "$DOWNLOAD_URL_PREFIX" "$BUNDLE_ID" "$BUILD_NUMBER" <<'PY'
import re, sys
from urllib.parse import urlsplit
for value in sys.argv[1:3]:
    url = urlsplit(value)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password
        or url.query or url.fragment or any(c.isspace() for c in value)
        or url.hostname in ('localhost', '127.0.0.1', '::1')
        or url.hostname.endswith(('.local', '.test', '.invalid', '.example'))
        or url.hostname in ('example.com', 'example.org', 'example.net')):
        sys.exit('ERROR: release URLs must be public HTTPS URLs without credentials, queries or fragments.')
if not sys.argv[1].endswith('/appcast.xml') or not sys.argv[2].endswith('/'):
    sys.exit('ERROR: feed must end in /appcast.xml; download prefix must end in /.')
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', sys.argv[3]) or sys.argv[3].startswith('local.'):
    sys.exit('ERROR: choose a permanent reverse-DNS bundle ID before release.')
if not re.fullmatch(r'[1-9][0-9]*', sys.argv[4]):
    sys.exit('ERROR: BUILD_NUMBER must be a positive integer, higher than the previous release.')
PY
if [[ "$SIGN_IDENTITY" != 'Developer ID Application:'* ]] ||
   ! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
  echo "ERROR: Developer ID Application identity unavailable: $SIGN_IDENTITY" >&2
  echo 'Set SIGN_IDENTITY or configure .signing.local.sh from signing.example.sh.' >&2
  exit 1
fi

SIGN_UPDATE="$(find .build/artifacts/sparkle -type f -name sign_update 2>/dev/null | head -1)"
GEN_APPCAST="$(find .build/artifacts/sparkle -type f -name generate_appcast 2>/dev/null | head -1)"
if [ -z "$GEN_APPCAST" ]; then
  echo 'ERROR: Sparkle tools are missing. Run swift package resolve first.' >&2
  exit 1
fi
[ -n "$SIGN_UPDATE" ] || { echo 'ERROR: Sparkle sign_update is missing.' >&2; exit 1; }
PUBLIC_KEY="$(tr -d '[:space:]' < sparkle_public_key.txt)"
KEY_ARGS=(--account "$SPARKLE_ACCOUNT")
if [ -f sparkle_private_key.txt ]; then
  KEY_ARGS=(--ed-key-file "$PWD/sparkle_private_key.txt")
fi
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
printf 'Pomodoro release key verification\n' > "$STAGING/signing-probe.bin"
SIGNATURE="$("$SIGN_UPDATE" "${KEY_ARGS[@]}" -p "$STAGING/signing-probe.bin")"
swift Tools/VerifySparkleSignature.swift "$PUBLIC_KEY" "$SIGNATURE" "$STAGING/signing-probe.bin"
echo '==> Sparkle private key matches the embedded public key'

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > "$STAGING/notary-history.txt" 2>&1; then
  cat "$STAGING/notary-history.txt" >&2
  echo "ERROR: notarization credentials unavailable. Run: xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
  exit 1
fi
if [ "$VERSION" = --check ]; then
  echo "==> Release prerequisites verified for $BUNDLE_ID"
  exit 0
fi
for extension in dmg zip; do
  if [ -e "$RELEASES/Pomodoro-$VERSION.$extension" ]; then
    echo "ERROR: version $VERSION already exists. Choose a new version; published archives are immutable." >&2
    exit 1
  fi
done
if [ -f "$RELEASES/appcast.xml" ]; then
  "$PYTHON" - "$RELEASES/appcast.xml" "$BUILD_NUMBER" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
root = ET.parse(sys.argv[1])
versions = [n.text for n in root.iter(ns + 'version')]
versions += [n.get(ns + 'version') for n in root.iter('enclosure') if n.get(ns + 'version')]
if any(not v.isdigit() or int(v) >= int(sys.argv[2]) for v in versions):
    sys.exit('ERROR: BUILD_NUMBER must be greater than every published build.')
PY
fi

echo "==> Version $VERSION (build $BUILD_NUMBER)"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" RELEASE_BUILD=1 APP_OUTPUT="$APP" ./build.sh release
EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[ "$EMBEDDED_KEY" = "$PUBLIC_KEY" ] || { echo 'ERROR: embedded key changed during build.' >&2; exit 1; }

notarize() {
  local archive="$1" result="$2"
  # Retain the submission ID and status even if Apple rejects the upload.
  result="dist/Direct/$(basename "$result")"
  echo "==> Submitting $(basename "$archive") to Apple"
  if ! xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result"; then
    cat "$result" >&2
    echo "ERROR: notarization failed; submission result retained at $result" >&2
    return 1
  fi
  "$PYTHON" - "$result" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('Notarization:', result.get('status'), '| submission:', result.get('id'))
if result.get('status') != 'Accepted':
    sys.exit('ERROR: Apple did not accept this submission. Retrieve its notarytool log before retrying.')
PY
}

# Staple the app before packaging so the installed copy works offline too.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/notarization.zip"
notarize "$STAGING/notarization.zip" "$STAGING/app-notarization.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"

mkdir "$STAGING/image" "$STAGING/publish"
ditto "$APP" "$STAGING/image/Pomodoro.app"
ln -s /Applications "$STAGING/image/Applications"
OUT="Pomodoro-$VERSION.dmg"
if hdiutil create -volname Pomodoro -srcfolder "$STAGING/image" -format UDZO "$STAGING/publish/$OUT"; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$STAGING/publish/$OUT"
  notarize "$STAGING/publish/$OUT" "$STAGING/dmg-notarization.json"
  xcrun stapler staple "$STAGING/publish/$OUT"
  xcrun stapler validate "$STAGING/publish/$OUT"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGING/publish/$OUT"
else
  OUT="Pomodoro-$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/publish/$OUT"
fi

if [ -f "$RELEASES/appcast.xml" ]; then
  cp "$RELEASES/appcast.xml" "$STAGING/publish/appcast.xml"
fi
if "$GEN_APPCAST" "${KEY_ARGS[@]}" --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --maximum-deltas 0 -o "$STAGING/publish/appcast.xml" "$STAGING/publish"; then
  "$PYTHON" Tools/verify-appcast.py "$STAGING/publish/appcast.xml" "$STAGING/publish/$OUT" \
    "$EMBEDDED_KEY" "$BUILD_NUMBER" "$VERSION" "$DOWNLOAD_URL_PREFIX"
else
  echo 'ERROR: appcast generation failed; no release was published.' >&2
  exit 1
fi

mkdir -p "$RELEASES" dist/Direct
mv "$STAGING/publish/$OUT" "$RELEASES/$OUT"
mv "$STAGING/publish/appcast.xml" "$RELEASES/appcast.xml"
(cd "$RELEASES" && shasum -a 256 "$OUT" > "$OUT.sha256")
echo "==> Verified notarized release: $RELEASES/$OUT"
echo "    Upload the archive and checksum to $DOWNLOAD_URL_PREFIX, then appcast.xml to $APPCAST_URL."
echo '    Nothing has been uploaded by this script.'

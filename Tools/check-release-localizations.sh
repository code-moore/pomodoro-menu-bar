#!/usr/bin/env bash
# Stops a release whose strings aren't all translated. build.sh (with
# RELEASE_BUILD=1) and build-appstore.sh run it before their universal build,
# passing their own `swift build` flags without --arch:
#
#   Tools/check-release-localizations.sh -c release --scratch-path .build ...
#
# The universal build doesn't hand the compiler's list of strings on, so a
# build for this Mac alone makes it. The list is kept in the scratch folder:
# only recompiled files are re-listed, and only files whose source still
# exists count.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Checking translations"
extra=()
if [ "${APP_STORE:-}" = 1 ]; then
  STRINGS_DATA="$PWD/.build-appstore/localized-strings"
  # The catalog also holds the direct build's strings, such as Check for
  # Updates…, which the App Store build leaves out.
  extra=(--allow-unused)
else
  STRINGS_DATA="$PWD/.build/localized-strings"
fi
mkdir -p "$STRINGS_DATA"
swift build "$@" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS_DATA"
/usr/bin/python3 Tools/check-localizations.py --stringsdata "$STRINGS_DATA" --sources Sources \
  ${extra[@]+"${extra[@]}"} Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings

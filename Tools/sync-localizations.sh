#!/usr/bin/env bash
# Adds strings new in the code to Resources/Localizable.xcstrings, in English
# only, for translating. Strings the code no longer uses stay until deleted by
# hand: Tools/check-release-localizations.sh names them. Then translate, and
# check with
#   python3 Tools/check-localizations.py Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings
# Release builds run that check too, against the strings in the code.
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-module-cache"

# swiftc lists a file's strings only when it recompiles it, so the list is
# kept between runs, and only files whose source still exists are used.
STRINGS_DATA="$PWD/.build/localized-strings-debug"
mkdir -p "$STRINGS_DATA"
swift build --scratch-path "$PWD/.build" --disable-sandbox \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS_DATA"

current=()
while IFS= read -r source; do
  name="$(basename "$source" .swift)"
  [ ! -f "$STRINGS_DATA/$name.stringsdata" ] || current+=("$STRINGS_DATA/$name.stringsdata")
done < <(find Sources -name '*.swift')

xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "${current[@]}"
echo "==> Synced. New strings need translating into every language before a release."

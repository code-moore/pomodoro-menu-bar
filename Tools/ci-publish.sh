#!/usr/bin/env bash
set -euo pipefail
: "${GH_SOURCE_TOKEN:?Source token required}"
: "${GH_RELEASE_TOKEN:?Organisation token required}"
: "${GH_WEBSITE_TOKEN:?Website token required}"
SOURCE=msmfa/pomodoro-menu-bar
TARGET=code-moore/pomodoro-menu-bar
WEBSITE=msmfa/quiet-pomodoro
VERSION="$(cat releases/version.txt)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
test "$(cat releases/source-commit.txt)" = "$GITHUB_SHA"
TAG="v$VERSION"
DMG="Pomodoro-$VERSION.dmg"
(cd releases && sha256sum -c "$DMG.sha256")
cp "releases/$DMG" releases/Pomodoro-macos.dmg
cat > releases/notes.md <<NOTES
Pomodoro $VERSION for the macOS menu bar. Supports Apple Silicon and Intel Macs running macOS 14 or later.

Download the DMG, open it, and drag Pomodoro to Applications.

Built from $GITHUB_SHA. Automated tests passed. Signed with Developer ID and notarized by Apple.

Installed apps continue checking the signed update feed at quietpomodoro.com.
NOTES
# Tags decide what ships, so the current release is the highest version tag.
newest_tag() {
  GH_TOKEN="$GH_SOURCE_TOKEN" gh api "repos/$SOURCE/git/matching-refs/tags/v" --paginate --jq '.[].ref' |
    sed 's#^refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}
for repo in "$SOURCE" "$TARGET"; do
  export GH_TOKEN="$GH_SOURCE_TOKEN"
  asset="$DMG"
  target="$GITHUB_SHA"
  if [ "$repo" = "$TARGET" ]; then
    export GH_TOKEN="$GH_RELEASE_TOKEN"
    asset=Pomodoro-macos.dmg
    target=main
  fi
  (cd releases && sha256sum "$asset" > SHA256SUMS.txt)
  if gh release view "$TAG" -R "$repo" --json isDraft > releases/state.json 2>/dev/null; then
    if [ "$(python3 -c 'import json;print(json.load(open("releases/state.json"))["isDraft"])')" = False ]; then
      tmp="$(mktemp -d)"
      gh release download "$TAG" -R "$repo" -p SHA256SUMS.txt -D "$tmp"
      cmp releases/SHA256SUMS.txt "$tmp/SHA256SUMS.txt"
      rm -rf "$tmp"
      continue
    fi
  else
    gh release create "$TAG" -R "$repo" --target "$target" --draft --title "Pomodoro $VERSION" --notes-file releases/notes.md
  fi
  gh release upload "$TAG" -R "$repo" "releases/$asset" releases/SHA256SUMS.txt releases/appcast.xml releases/source-commit.txt --clobber
  latest=false
  if [ "$(newest_tag)" = "$TAG" ]; then latest=true; fi
  gh release edit "$TAG" -R "$repo" --draft=false --latest="$latest"
done
# An old build can remain downloadable, but must not replace the live website.
if [ "$(newest_tag)" != "$TAG" ]; then
  echo 'A newer release tag exists; leaving the website unchanged.'
  exit 0
fi
export GH_TOKEN="$GH_WEBSITE_TOKEN"
gh repo clone "$WEBSITE" website -- --depth 1 --branch master
DEST=website/site/dist/downloads/mac
if [ -e "$DEST/$DMG" ]; then
  cmp "releases/$DMG" "$DEST/$DMG"
else
  cp "releases/$DMG" "releases/$DMG.sha256" "$DEST/"
fi
cp releases/appcast.xml "$DEST/appcast.xml"
python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path('website/site/scripts/mac-release.mjs')
s,n=re.subn(r"export const MAC_VERSION = '[^']+';", "export const MAC_VERSION = '"+sys.argv[1]+"';", p.read_text())
assert n==1
p.write_text(s)
PY
(cd website/site && npm ci && npm run build:ci)
git -C website add site/dist/downloads/mac site/scripts/mac-release.mjs
if ! git -C website diff --cached --quiet; then
  git -C website -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -m "Publish Pomodoro $VERSION from $GITHUB_SHA"
  git -C website -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin master
fi
printf 'Published Pomodoro %s from %s. Website deployment follows its existing Cloudflare build.\n' "$VERSION" "$GITHUB_SHA" >> "$GITHUB_STEP_SUMMARY"

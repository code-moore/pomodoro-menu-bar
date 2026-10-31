#!/usr/bin/env bash
set -euo pipefail
: "${GH_SOURCE_TOKEN:?Source token required}"
: "${GH_WEBSITE_TOKEN:?Website token required}"
SOURCE=code-moore/pomodoro-menu-bar
WEBSITE=msmfa/quiet-pomodoro
VERSION="$(cat releases/version.txt)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
test "$(cat releases/source-commit.txt)" = "$GITHUB_SHA"
TAG="v$VERSION"
DMG="Pomodoro-$VERSION.dmg"
(cd releases && sha256sum -c "$DMG.sha256")
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
publish_source_release() {
  (cd releases && sha256sum "$DMG" > SHA256SUMS.txt)
  if gh release view "$TAG" -R "$SOURCE" --json isDraft > releases/state.json 2>/dev/null; then
    if [ "$(python3 -c 'import json;print(json.load(open("releases/state.json"))["isDraft"])')" = False ]; then
      tmp="$(mktemp -d)"
      gh release download "$TAG" -R "$SOURCE" -p SHA256SUMS.txt -D "$tmp"
      cmp releases/SHA256SUMS.txt "$tmp/SHA256SUMS.txt"
      rm -rf "$tmp"
      return
    fi
  else
    gh release create "$TAG" -R "$SOURCE" --target "$GITHUB_SHA" --draft --title "Pomodoro $VERSION" --notes-file releases/notes.md
  fi
  gh release upload "$TAG" -R "$SOURCE" "releases/$DMG" releases/SHA256SUMS.txt releases/appcast.xml releases/source-commit.txt --clobber
  latest=false
  if [ "$(newest_tag)" = "$TAG" ]; then latest=true; fi
  gh release edit "$TAG" -R "$SOURCE" --draft=false --latest="$latest"
}
export GH_TOKEN="$GH_SOURCE_TOKEN"
publish_source_release
# An old build can remain downloadable, but must not replace the live website.
if [ "$(newest_tag)" != "$TAG" ]; then
  echo 'A newer release tag exists; leaving the website unchanged.'
  exit 0
fi
export GH_TOKEN="$GH_WEBSITE_TOKEN"
gh repo clone "$WEBSITE" website -- --depth 1 --branch master
WEBSITE_BRANCH="release/pomodoro-$TAG"
website_git() {
  git -C website -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"
}
# Resume a partially published website PR without rewriting its history.
existing_branch="$(website_git ls-remote --heads origin "refs/heads/$WEBSITE_BRANCH")"
if [ -n "$existing_branch" ]; then
  website_git fetch --unshallow origin "master:refs/remotes/origin/master" "$WEBSITE_BRANCH:refs/remotes/origin/$WEBSITE_BRANCH"
  website_git switch -c "$WEBSITE_BRANCH" "origin/$WEBSITE_BRANCH"
  website_git merge --no-edit origin/master
else
  website_git switch -c "$WEBSITE_BRANCH"
fi
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
website_git add site/dist/downloads/mac site/scripts/mac-release.mjs
if ! website_git diff --cached --quiet; then
  website_git commit -m "Publish Pomodoro $VERSION from $GITHUB_SHA"
fi
if ! website_git diff --quiet origin/master HEAD; then
  website_git push origin "HEAD:refs/heads/$WEBSITE_BRANCH"
  WEBSITE_PR="$(gh pr list -R "$WEBSITE" --base master --head "$WEBSITE_BRANCH" --state open --json number --jq '.[0].number // empty')"
  if [ -z "$WEBSITE_PR" ]; then
    cat > releases/website-pr.md <<NOTES
Publish the verified Pomodoro $VERSION archive, checksum and signed update feed from source commit $GITHUB_SHA, and update MAC_VERSION.

Validation: the website build passed with npm run build:ci. Merging deploys through the existing Cloudflare build.
NOTES
    WEBSITE_PR="$(gh pr create -R "$WEBSITE" --base master --head "$WEBSITE_BRANCH" --title "Publish Pomodoro $VERSION" --body-file releases/website-pr.md)"
    WEBSITE_PR="${WEBSITE_PR##*/}"
  fi
  gh pr merge "$WEBSITE_PR" -R "$WEBSITE" --merge --author-email 59375712+msmfa@users.noreply.github.com \
    --match-head-commit "$(website_git rev-parse HEAD)"
fi
printf 'Published Pomodoro %s from %s. Website deployment follows its existing Cloudflare build.\n' "$VERSION" "$GITHUB_SHA" >> "$GITHUB_STEP_SUMMARY"

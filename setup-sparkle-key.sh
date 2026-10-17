#!/usr/bin/env bash
# Keep the update signing secret in Keychain; commit only its public half.
set -euo pipefail
cd "$(dirname "$0")"
ACCOUNT="${SPARKLE_ACCOUNT:-com.codemoore.pomodoro.menubar}"
TOOL="$(find .build/artifacts/sparkle -type f -name generate_keys 2>/dev/null | head -1)"
[ -n "$TOOL" ] || { echo 'Run swift package resolve first.' >&2; exit 1; }
if [ -f sparkle_private_key.txt ]; then
  echo 'Existing file key preserved. ./release.sh --check verifies it before release.'
  exit 0
fi
PUBLIC="$("$TOOL" --account "$ACCOUNT" -p 2>/dev/null || true)"
if [[ ! "$PUBLIC" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  if [ -s sparkle_public_key.txt ]; then
    echo 'ERROR: the tracked public key has no Keychain private key. Restore the original key; do not silently rotate a released app.' >&2
    exit 1
  fi
  "$TOOL" --account "$ACCOUNT"
  PUBLIC="$("$TOOL" --account "$ACCOUNT" -p)"
fi
if [ -s sparkle_public_key.txt ] && [ "$(tr -d '[:space:]' < sparkle_public_key.txt)" != "$PUBLIC" ]; then
  echo 'ERROR: Keychain and tracked public keys differ. Restore the matching key before releasing.' >&2
  exit 1
fi
printf '%s\n' "$PUBLIC" > sparkle_public_key.txt
echo "==> Public key saved; private key remains in Keychain account $ACCOUNT."

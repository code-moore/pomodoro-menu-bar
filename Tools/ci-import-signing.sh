#!/usr/bin/env bash
set -euo pipefail
for name in CERT PASSWORD NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_PRIVATE_KEY SPARKLE_KEY; do
  test -n "${!name:-}" || { echo "Missing release credential: $name" >&2; exit 1; }
done
umask 077
KEYCHAIN="$RUNNER_TEMP/pomodoro-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf '%s' "$CERT" | base64 --decode > "$RUNNER_TEMP/certificate.p12"
printf '%s' "$NOTARY_PRIVATE_KEY" > "$RUNNER_TEMP/notary-key.p8"
printf '%s' "$SPARKLE_KEY" > sparkle_private_key.txt
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
security import "$RUNNER_TEMP/certificate.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
xcrun notarytool store-credentials "$NOTARY_PROFILE" --key "$RUNNER_TEMP/notary-key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
rm -f "$RUNNER_TEMP/certificate.p12" "$RUNNER_TEMP/notary-key.p8"

#!/usr/bin/env bash
# Prints the running app's self-reported state.
#
# The app can't be screenshotted from a sandboxed shell, so it records what it
# actually computed and this reads it back. Use it to verify behaviour instead
# of asking what the interface looks like.
set -euo pipefail

DOMAIN="${BUNDLE_ID:-com.codemoore.pomodoro.menubar}"

echo "=== process ==="
if pgrep -x Pomodoro >/dev/null; then
  echo "  running (pid $(pgrep -x Pomodoro))"
else
  echo "  NOT RUNNING"
fi

echo
echo "=== updater (Sparkle) ==="
defaults read "$DOMAIN" updaterDiagnostics 2>/dev/null | sed 's|^|  |' || echo "  (not recorded)"

echo
echo "=== planner ==="
defaults read "$DOMAIN" diagnostics 2>/dev/null || echo "  (not recorded)"

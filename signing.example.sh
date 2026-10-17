# Copy to .signing.local.sh (ignored by Git) and replace the placeholders.
# Environment variables take precedence over these local defaults.
# Keep passwords and private keys in Keychain, never in this file.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Your Name (TEAM_ID)}"
TEAM_ID="${TEAM_ID:-TEAM_ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pomodoro}"

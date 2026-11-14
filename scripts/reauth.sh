#!/bin/bash
# Re-authenticate all Google Workspace MCP accounts in sequence.
#
# Walks every account under ~/.config/gws/accounts/, checks whether its
# refresh token still works, and only runs the interactive `gws auth login`
# flow for the ones that are stale. Pass --force to re-auth all of them
# regardless of current state.
#
# Install next to the launcher:
#   cp scripts/reauth.sh ~/.config/gws/reauth.sh && chmod +x ~/.config/gws/reauth.sh
#
# Usage:
#   ~/.config/gws/reauth.sh            # re-auth only stale accounts
#   ~/.config/gws/reauth.sh --force    # re-auth every account
#
# If you find yourself running this every week, the script is not the fix:
# your OAuth consent screen is still in "Testing", which caps refresh tokens
# at 7 days. Publish the app to production (docs/manual-setup.md, Step 5),
# then run this once with --force. Tokens issued while in Testing keep their
# 7-day expiry, so every account needs one fresh login after publishing.

set -uo pipefail

ACCOUNTS_DIR="$HOME/.config/gws/accounts"
# Explicit scope URLs, passed with --scopes. Do NOT switch back to
# `-s drive,gmail,...`: on gws 0.7.0 that form silently adds the
# https://www.googleapis.com/auth/cloud-platform scope, and Google documents
# that tokens carrying it are subject to Workspace "Google Cloud session
# control" reauthentication (1-24h, admin-configured). Edit this list if you
# need other services; keep it to full scope URLs.
SCOPES="openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/documents"
KEYRING_BACKEND="file"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ ! -d "$ACCOUNTS_DIR" ]; then
  echo "Error: $ACCOUNTS_DIR not found" >&2
  exit 1
fi

# Run a gws subcommand against a given account config dir.
gws_for() {
  local dir="$1"; shift
  env GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$dir" \
      GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND="$KEYRING_BACKEND" \
      gws "$@"
}

# Return 0 if the account's token currently works, non-zero otherwise.
token_ok() {
  gws_for "$1" gmail users getProfile --params '{"userId":"me"}' 2>&1 \
    | grep -q '"emailAddress"'
}

stale=()
ok=()

echo "Checking accounts in $ACCOUNTS_DIR ..."
for dir in "$ACCOUNTS_DIR"/*/; do
  [ -d "$dir" ] || continue
  acct="$(basename "$dir")"
  if [ "$FORCE" -eq 0 ] && token_ok "$dir"; then
    echo "  [ok]    $acct"
    ok+=("$acct")
  else
    echo "  [stale] $acct -> needs re-auth"
    stale+=("$dir")
  fi
done

if [ "${#stale[@]}" -eq 0 ]; then
  echo
  echo "All accounts authenticated. Nothing to do."
  exit 0
fi

echo
echo "Re-authenticating ${#stale[@]} account(s). A browser window will open for each."
echo "Complete each sign-in, then return here for the next one."
echo

for dir in "${stale[@]}"; do
  acct="$(basename "$dir")"
  echo "=== $acct ==="
  gws_for "$dir" auth login --scopes "$SCOPES"
  echo
done

echo "Verifying ..."
fail=0
for dir in "$ACCOUNTS_DIR"/*/; do
  [ -d "$dir" ] || continue
  acct="$(basename "$dir")"
  email="$(gws_for "$dir" gmail users getProfile --params '{"userId":"me"}' 2>&1 \
            | sed -n 's/.*"emailAddress": *"\([^"]*\)".*/\1/p')"
  if [ -n "$email" ]; then
    echo "  [ok]    $acct -> $email"
  else
    echo "  [FAIL]  $acct -> still not authenticated"
    fail=1
  fi
done

exit "$fail"

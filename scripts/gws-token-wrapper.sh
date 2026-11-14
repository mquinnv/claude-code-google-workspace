#!/bin/bash
# Per-account Google Workspace MCP launcher.
#
# Each account has its own isolated config dir at <account-dir>/ containing
# its own client_secret.json and file-backed encrypted credentials (created
# by `gws auth login` with KEYRING_BACKEND=file; see scripts/reauth.sh).
# `gws mcp` refreshes access tokens internally from the encrypted creds — no
# 1-hour expiry issue. The refresh token itself still expires after 7 days if
# the OAuth consent screen is left in "Testing" (docs/manual-setup.md, Step 5).
#
# Usage: gws-token-wrapper.sh <account-config-dir> [gws mcp args...]
# Example: gws-token-wrapper.sh ~/.config/gws/accounts/personal -s gmail,drive

set -euo pipefail

ACCOUNT_DIR="$1"
shift

if [ ! -d "$ACCOUNT_DIR" ]; then
  echo "Error: Account config dir not found: $ACCOUNT_DIR" >&2
  exit 1
fi

if [ ! -f "$ACCOUNT_DIR/client_secret.json" ]; then
  echo "Error: $ACCOUNT_DIR/client_secret.json missing" >&2
  exit 1
fi

if [ ! -f "$ACCOUNT_DIR/credentials.enc" ]; then
  echo "Error: $ACCOUNT_DIR not authenticated. Run:" >&2
  echo "  ~/.config/gws/reauth.sh" >&2
  echo "(install it from scripts/reauth.sh, or see docs/manual-setup.md Step 8 for the manual login command)" >&2
  exit 1
fi

exec env GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$ACCOUNT_DIR" \
         GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
         gws mcp "$@"

# Claude Code Google Workspace + Slack MCP Setup

This repo helps users set up Google Workspace and Slack MCP servers for Claude Code AND Claude Desktop.

## Your Role

You are a setup assistant. Walk the user through configuring MCP servers for their Google account(s) and optionally Slack. Be concise and direct.

## Setup Flow

### Step 1: Install Google Workspace CLI

```bash
npm install -g @googleworkspace/cli@0.7.0
```

Verify: `gws --version` (must be **0.7.x exactly**)

**CRITICAL:** The `gws mcp` subcommand was REMOVED in v0.8.0 (commit dd3fc90, PR #275). 0.7.0 is the last version where `gws mcp` exists. Do NOT install latest. If the user has a different `gws` on PATH (e.g. the Homebrew package — a different "git workspace" tool), uninstall it first: `brew uninstall gws`.

### Step 2: Create GCP Project

Guide the user to https://console.cloud.google.com/projectcreate

- Project name: something like `gws-mcp` (must be globally unique)
- Note the project ID — you'll need it
- Sign in with whatever Google account should OWN the project. For users with both personal and workspace accounts, personal Gmail is usually cleanest (no employer IT policy risk; survives leaving the company).

### Step 3: Enable APIs

```bash
gcloud services enable gmail.googleapis.com drive.googleapis.com calendar-json.googleapis.com sheets.googleapis.com docs.googleapis.com --project=PROJECT_ID
```

If `gcloud` is logged in as a DIFFERENT account than the project owner, log it in first:
```bash
gcloud auth login OWNER_EMAIL
```

### Step 4: Grant API access to other accounts

If accounts OTHER than the project owner will call APIs against this project, grant them `serviceusage.serviceUsageConsumer`:

```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="user:OTHER_EMAIL" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --condition=None
```

### Step 5: Create OAuth Consent Screen

Guide user to: `https://console.cloud.google.com/apis/credentials/consent?project=PROJECT_ID`

- User Type: External (unless Google Workspace admin)
- App name: anything (e.g., "Claude MCP")
- Support email: user's email
- Scopes: skip (scopes are requested at login)
- Test users: **Add ALL Google accounts** they want to use (critical for unverified apps)
- Save

### Step 6: Create OAuth Client (one per Google account)

Guide user to: `https://console.cloud.google.com/apis/credentials?project=PROJECT_ID`

For EACH Google account:
1. Create Credentials → OAuth client ID
2. Application type: **Desktop app**
3. Name: descriptive (e.g., "MCP - personal" or "MCP - work")
4. Download the JSON

Have the user save / rename each downloaded JSON to something memorable like `personal-oauth.json`, `work-oauth.json`, etc. We'll move them into the right place next.

**CRITICAL: Each Google account MUST have its own OAuth client.** Using one client for two accounts causes refresh token invalidation.

### Step 7: Set up per-account config dirs

For each account (e.g. `personal`, `work`, `iai`):

```bash
mkdir -p ~/.config/gws/accounts/ACCOUNTNAME
mv ~/Downloads/ACCOUNTNAME-oauth.json ~/.config/gws/accounts/ACCOUNTNAME/client_secret.json
```

This is the **critical architectural choice**: each account gets its own `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` with its own file-backed encrypted credential store. This is what enables `gws mcp` to refresh access tokens internally — no 1-hour expiry issue.

### Step 8: Authenticate Each Account

For each account, run:

```bash
env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$HOME/.config/gws/accounts/ACCOUNTNAME \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
    gws auth login -s drive,gmail,calendar,sheets,docs
```

The browser opens — make sure the user signs in with the **correct** Google account for this command. `KEYRING_BACKEND=file` causes credentials to be stored in `credentials.enc` inside the per-account config dir, isolated from the system keyring (which only holds one account at a time).

Verify each account routes correctly:
```bash
env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$HOME/.config/gws/accounts/ACCOUNTNAME \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
    gws drive about get --params '{"fields":"user(emailAddress)"}'
```

Should return the email of THAT account.

### Step 9: Install MCP Launcher Script

```bash
cp scripts/gws-token-wrapper.sh ~/.config/gws/gws-token-wrapper.sh
chmod +x ~/.config/gws/gws-token-wrapper.sh
```

The script is a thin shim — it sets `CONFIG_DIR` + `KEYRING_BACKEND=file` and execs `gws mcp`. `gws mcp` then handles its own token refresh from the per-account encrypted creds.

### Step 10: Register the MCP servers

Two scopes to consider:

- **Claude Code, user scope** (available in all projects):
  ```bash
  claude mcp add --scope user gws-ACCOUNTNAME -- \
    $HOME/.config/gws/gws-token-wrapper.sh \
    $HOME/.config/gws/accounts/ACCOUNTNAME \
    -s gmail,drive,calendar,sheets,docs
  ```
  Note the `--` separator (so `claude mcp add` doesn't try to parse `-s` as its own flag).

- **Claude Code, project scope** (only in a specific project): create `.mcp.json` at the project root:
  ```json
  {
    "mcpServers": {
      "gws-ACCOUNTNAME": {
        "command": "HOME_DIR/.config/gws/gws-token-wrapper.sh",
        "args": [
          "HOME_DIR/.config/gws/accounts/ACCOUNTNAME",
          "-s", "gmail,drive,calendar,sheets,docs"
        ]
      }
    }
  }
  ```
  `.mcp.json` MUST be at the project root. `settings.local.json` SILENTLY IGNORES `mcpServers`.

- **Claude Desktop / Cowork**: edit `~/Library/Application Support/Claude/claude_desktop_config.json` and add an `mcpServers` block at the top level. Same JSON shape as `.mcp.json`. Disable the built-in `claude.ai` Google connectors in Settings → Connectors — they're read-only and the model may pick them over our write-capable ones.

### Step 11: Restart Claude Code / Claude Desktop

MCP servers only load at startup. Restart to pick up the new config.

### Step 12: Test

```
# List recent emails
mcp__gws-ACCOUNTNAME__gmail_users_messages_list(params: {"userId": "me", "maxResults": 3})

# Search Drive
mcp__gws-ACCOUNTNAME__drive_files_list(params: {"q": "name contains 'test'", "pageSize": 5})
```

## Slack Setup (Optional)

### Create Slack App

1. Go to https://api.slack.com/apps → Create New App → From scratch
2. Name: "Claude MCP" (or anything)
3. Select workspace

### Add OAuth Scopes

OAuth & Permissions → User Token Scopes → Add:
- `channels:history`, `channels:read`
- `groups:history`, `groups:read`
- `im:history`, `im:read`
- `mpim:history`, `mpim:read`
- `search:read`
- `users:read`, `users:read.email`
- `usergroups:read`

Optional (for posting):
- `chat:write`

### Install to Workspace

OAuth & Permissions → Install to Workspace → Copy the `xoxp-...` User OAuth Token.

### Add to MCP config

```json
"slack": {
  "command": "npx",
  "args": ["-y", "slack-mcp-server@latest"],
  "env": {
    "SLACK_MCP_XOXP_TOKEN": "xoxp-your-token-here"
  }
}
```

**Note:** Message posting is disabled by default in `slack-mcp-server`. To enable, add `"SLACK_MCP_ADD_MESSAGE_TOOL": "true"` to the `env` section.

## Troubleshooting

### MCP servers don't appear after restart
- Verify `.mcp.json` is at the **project root** (same directory as `.git/`)
- NOT inside `.claude/` — that doesn't work
- NOT in `settings.local.json` — silently ignored
- For Claude Desktop: check `~/Library/Application Support/Claude/claude_desktop_config.json` is valid JSON with `mcpServers` at the top level

### "Permission denied" on API calls
- Check the GCP project has the right APIs enabled
- For accounts other than the project owner: verify they have `roles/serviceusage.serviceUsageConsumer` on the GCP project (see Step 4)

### Wrong account's data returned
- Each account MUST use its own per-account config dir (Step 7) authenticated with `KEYRING_BACKEND=file` (Step 8)
- If accounts share a single config dir or rely on the system keyring, the last-logged-in account wins for everyone
- Each account MUST use a different OAuth client ID

### "Access blocked" during OAuth
- Add the account as a test user on the OAuth consent screen (Step 5)

### "Invalid authentication credentials" after some time
- Tokens are refreshed internally by `gws mcp` using the encrypted creds in each per-account dir — there should be NO 1-hour expiry issue.
- If you ARE seeing this on a long-running session: the user likely set things up with the old "mint-token-once-at-startup" wrapper. Re-do Steps 7–9 with the per-account-dir approach.
- Also disable the built-in `claude.ai` Google connectors in Claude Desktop — they're read-only and intercept tool calls.

### Read-only access in Claude Desktop despite write scopes
- Claude Desktop ships with built-in `claude.ai` Gmail/Drive/Calendar connectors that are read-only.
- Settings → Connectors → disable Gmail, Google Drive, Google Calendar.
- Our `gws-*` MCPs then handle everything with full read+write.

## Re-authentication

If credentials get revoked or you need to re-grant scopes:

```bash
env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$HOME/.config/gws/accounts/ACCOUNTNAME \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
    gws auth login -s drive,gmail,calendar,sheets,docs
```

No restart needed unless the MCP process itself has crashed.

## Key Gotchas (Read Before Debugging)

1. **`gws` must be pinned to 0.7.0** — `gws mcp` was removed in 0.8.0+
2. **`mcpServers` in `settings.local.json` is SILENTLY IGNORED** — no error, no log, servers just don't start
3. **`.mcp.json` must be at project root** — not inside `.claude/`
4. **One OAuth client per Google account** — same client_id across accounts = token invalidation
5. **One config dir per account** — `KEYRING_BACKEND=file` with isolated `CONFIG_DIR` is what makes multi-account work
6. **MCP servers start at session launch only** — config changes require restart
7. **`gws` uses single-dash CLI flags** — `-s drive` not `--scope drive`
8. **`.mcp.json` contains no secrets in this setup** — secrets are in `~/.config/gws/accounts/*/credentials.enc`, but the per-account-dir paths still shouldn't leak in repos
9. **Claude Desktop built-in Google connectors are read-only** — disable them or write calls will silently fail
10. **For `claude mcp add` with `-s` in inner command** — use `--` separator: `claude mcp add gws-foo -- wrapper.sh dir -s drive`

# Manual Setup Guide

Step-by-step instructions for setting up Google Workspace + Slack MCP servers in Claude Code AND Claude Desktop without AI assistance.

## Google Workspace MCP

### 1. Install the Google Workspace CLI (pinned to 0.7.0)

```bash
# If Homebrew's git-workspace `gws` is installed, uninstall it first:
brew uninstall gws 2>/dev/null

npm install -g @googleworkspace/cli@0.7.0
gws --version  # must be 0.7.x
```

**Why pinned:** `gws mcp` was removed in v0.8.0 (PR #275). 0.7.0 is the last version with the MCP subcommand. Do NOT `npm update` this package.

### 2. Create a GCP Project

1. Go to https://console.cloud.google.com/projectcreate (signed in with the account that should OWN the project — personal Gmail is usually cleanest)
2. Name it something like `gws-mcp` (project ID must be globally unique)
3. Note the project ID

### 3. Enable APIs

```bash
# If gcloud isn't logged in as the project owner:
gcloud auth login OWNER_EMAIL

gcloud services enable \
  gmail.googleapis.com \
  drive.googleapis.com \
  calendar-json.googleapis.com \
  sheets.googleapis.com \
  docs.googleapis.com \
  --project=YOUR_PROJECT_ID
```

### 4. Grant API access to other accounts (if any)

For each non-owner account that will use this project:

```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:OTHER_EMAIL" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --condition=None
```

### 5. Configure OAuth Consent Screen

1. Go to: `https://console.cloud.google.com/apis/credentials/consent?project=YOUR_PROJECT_ID`
2. Select **External** user type
3. Fill in:
   - App name: "Claude MCP" (anything works)
   - User support email: your email
   - Developer contact: your email
4. Skip scopes (they're requested at login time)
5. **Add test users**: Add **every Google account** you want to connect (only needed while the app is in Testing)
6. Save
7. **Publish the app** — do not leave it in Testing. See below.

#### Publish to production (or re-authenticate every 7 days)

A new External app starts with publishing status **Testing**. Google expires refresh tokens issued to a Testing app after **7 days** ([OAuth docs, "Refresh token expiration"](https://developers.google.com/identity/protocols/oauth2#expiration)). The symptom is every account failing with an auth error about a week after login, and again a week after each re-login. You can see it directly: while the app is in Testing, the token endpoint's response to a refresh carries `refresh_token_expires_in` of roughly 604,800 seconds (7 days); after publishing and logging in again the field is absent.

Fix: Google Auth Platform → **Audience** → **Publish app** (status becomes "In production"). You do **not** need to submit the app for verification for personal use.

- **The Publish button is greyed out until Branding is complete.** Under Google Auth Platform → **Branding**, fill in the application home page, privacy policy link and terms of service link, and add an authorized domain that matches those links.
- **Unverified-app warning.** With no verification submitted, sign-in shows "Google hasn't verified this app". Click Advanced → continue. This is expected.
- **Google Workspace accounts may be blocked.** If a Workspace account gets "This app is blocked" after publishing, that organisation restricts unverified third-party apps. A Workspace admin must mark that account's OAuth client ID as **Trusted** in the Admin console: Security → Access and data control → API controls → Manage app access. Personal Gmail accounts, and Workspace orgs without that restriction, only show the unverified-app warning.
- **Log in once more after publishing.** Tokens issued while the app was in Testing keep their 7-day expiry. Re-run the Step 8 login (or `reauth.sh --force`) for every account after you publish.

### 6. Create OAuth Desktop Client(s)

Go to: `https://console.cloud.google.com/apis/credentials?project=YOUR_PROJECT_ID`

**For each Google account you want to connect:**

1. Click "Create Credentials" → "OAuth client ID"
2. Application type: **Desktop app**
3. Name: something descriptive (e.g., "MCP - personal", "MCP - work")
4. Click "Create"
5. Download the JSON file
6. We'll place each file into its account's isolated config directory next.

**Why separate clients?** Using the same OAuth client ID for two Google accounts causes the second login to invalidate the first account's refresh token. This is an OAuth2 behavior, not a bug.

### 7. Set up per-account isolated config directories

For each account (e.g., `personal`, `work`):

```bash
mkdir -p ~/.config/gws/accounts/personal
mkdir -p ~/.config/gws/accounts/work

# Move each downloaded OAuth client file into its account dir, renamed:
mv ~/Downloads/<personal-client>.json ~/.config/gws/accounts/personal/client_secret.json
mv ~/Downloads/<work-client>.json    ~/.config/gws/accounts/work/client_secret.json
```

**Why isolated dirs?** The `gws` CLI defaults to the system keyring, which only stores credentials for one account at a time. Without isolation, the last login wins for every account. We give each account its own `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` and use `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` so credentials live in a per-account `credentials.enc` that `gws mcp` can decrypt and refresh internally.

### 8. Authenticate Each Account

For each account, run:

```bash
env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$HOME/.config/gws/accounts/personal \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
    gws auth login --scopes "openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/documents"
# Browser opens — sign in as the personal account
```

Repeat for `work` (and any other accounts), substituting the dir. Or let `scripts/reauth.sh` do it: it walks every dir under `~/.config/gws/accounts/` and runs this same login for each account that is not currently authenticated (see Step 9).

**Why `--scopes` with full URLs instead of `-s drive,gmail,...`?** On `gws` 0.7.0 the `-s` service shorthand also requests `https://www.googleapis.com/auth/cloud-platform` (visible in `gws auth status` afterwards). Google documents that tokens carrying the Cloud Platform scope are subject to a Workspace org's "Google Cloud session control" reauthentication policy (1–24 hours, admin-configured), which would force re-login far more often than the token lifetime suggests. The explicit `--scopes` list requests exactly the scopes above and nothing else. We have not confirmed session control was expiring tokens in practice — treat it as a risk worth removing, not a diagnosed failure. Related `gws` issues: [googleworkspace/cli#562](https://github.com/googleworkspace/cli/issues/562), [#741](https://github.com/googleworkspace/cli/issues/741), [#918](https://github.com/googleworkspace/cli/issues/918).

This applies to **`gws auth login` only**. The `-s gmail,drive,calendar,sheets,docs` argument passed to `gws mcp` in the server definitions below selects which services' tools to expose; it is not an OAuth scope request and stays as it is.

**Verify** each account routes correctly:

```bash
env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$HOME/.config/gws/accounts/personal \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
    gws drive about get --params '{"fields":"user(emailAddress)"}'
```

The returned email should match the account you authenticated with.

### 9. Install the Launcher and Re-auth Scripts

```bash
cp scripts/gws-token-wrapper.sh scripts/reauth.sh ~/.config/gws/
chmod +x ~/.config/gws/gws-token-wrapper.sh ~/.config/gws/reauth.sh
```

**What it does:** Thin shim that sets `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` and execs `gws mcp`. `gws mcp` then refreshes access tokens from the per-account `credentials.enc` as needed — no 1-hour expiry.

**`reauth.sh`:** checks every account under `~/.config/gws/accounts/` and runs the Step 8 login only for the ones whose credentials no longer work (`--force` re-does all of them). You should rarely need it once the app is published (Step 5).

---

## Slack MCP (Optional)

### 1. Create a Slack App

1. Go to https://api.slack.com/apps
2. "Create New App" → "From scratch"
3. Name: "Claude MCP" (anything)
4. Select your workspace

### 2. Configure Scopes

Go to "OAuth & Permissions" → "User Token Scopes" → Add these scopes:

**Required (read-only):**
- `channels:history` — read public channel messages
- `channels:read` — list public channels
- `groups:history` — read private channel messages
- `groups:read` — list private channels
- `im:history` — read DMs
- `im:read` — list DMs
- `mpim:history` — read group DMs
- `mpim:read` — list group DMs
- `search:read` — search messages
- `users:read` — list users
- `users:read.email` — see user emails
- `usergroups:read` — list user groups

**Optional (for posting):**
- `chat:write` — send messages

### 3. Install to Workspace

1. "OAuth & Permissions" → "Install to Workspace"
2. Authorize
3. Copy the **User OAuth Token** (`xoxp-...`)

---

## Configure Claude Code / Claude Desktop

You have three places to register MCP servers, pick whichever fits:

### Option A: Claude Code user scope (available in all projects)

```bash
claude mcp add --scope user gws-personal -- \
  $HOME/.config/gws/gws-token-wrapper.sh \
  $HOME/.config/gws/accounts/personal \
  -s gmail,drive,calendar,sheets,docs
```

Note the `--` separator so `claude mcp add` doesn't try to parse `-s` as its own scope flag.

Repeat for `gws-work` etc.

### Option B: Claude Code project scope (`.mcp.json` at project root)

```json
{
  "mcpServers": {
    "gws-personal": {
      "command": "/Users/YOUR_USERNAME/.config/gws/gws-token-wrapper.sh",
      "args": [
        "/Users/YOUR_USERNAME/.config/gws/accounts/personal",
        "-s", "gmail,drive,calendar,sheets,docs"
      ]
    },
    "gws-work": {
      "command": "/Users/YOUR_USERNAME/.config/gws/gws-token-wrapper.sh",
      "args": [
        "/Users/YOUR_USERNAME/.config/gws/accounts/work",
        "-s", "gmail,drive,calendar,sheets,docs"
      ]
    },
    "slack": {
      "command": "npx",
      "args": ["-y", "slack-mcp-server@latest"],
      "env": {
        "SLACK_MCP_XOXP_TOKEN": "xoxp-your-token-here"
      }
    }
  }
}
```

Replace `YOUR_USERNAME` with your actual home dir.

### Option C: Claude Desktop / Cowork

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` — add an `mcpServers` block at the top level with the same shape as Option B.

**Important:** Claude Desktop ships with built-in `claude.ai` connectors for Gmail, Google Drive, and Google Calendar. They are **read-only**. The model may pick those over our write-capable `gws-*` MCPs. Go to Settings → Connectors and disable the built-in Google connectors.

### Gitignore

If using `.mcp.json` in a real project, add it to `.gitignore`. (The new architecture doesn't put OAuth secrets in `.mcp.json` directly — they live in `~/.config/gws/accounts/*/credentials.enc` — but the per-account dir paths can still leak environment info.)

### Restart Claude Code / Claude Desktop

MCP servers only load at session launch.

---

## Verify It Works

After restarting:

```
# Gmail — list recent emails
mcp__gws-personal__gmail_users_messages_list(params: {"userId": "me", "maxResults": 3})

# Drive — search files
mcp__gws-personal__drive_files_list(params: {"q": "modifiedTime > '2024-01-01'", "pageSize": 5, "fields": "files(id,name)"})

# Slack — list channels
mcp__slack__channels_list(channel_types: "public_channel")
```

If tools don't appear:
1. `.mcp.json` is at the project root (not inside `.claude/`)
2. You restarted Claude Code / Claude Desktop
3. Wrapper script is executable (`chmod +x`)
4. Account dirs exist with both `client_secret.json` AND `credentials.enc`

---

## Troubleshooting

See the [README](../README.md#known-gotchas) for a full table.

### Common Issues

**"Unknown service 'mcp'" when wrapper runs:**
→ `gws` is on a version ≥ 0.8.0. Pin to 0.7.0: `npm install -g @googleworkspace/cli@0.7.0 --force`.

**Wrong account's data returned:**
→ Each account needs its OWN `~/.config/gws/accounts/<name>/` dir, authenticated via the Step 8 `gws auth login` command with `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`. If accounts share a dir or rely on the system keyring, the last login wins for everyone.

**Every account stops working about 7 days after login (auth errors, `invalid_grant`):**
→ The OAuth consent screen is still in Testing, which caps refresh tokens at 7 days. Publish the app (Step 5, "Publish to production"), then run `~/.config/gws/reauth.sh --force` once.

**"Invalid authentication credentials" after about an hour (especially Claude Desktop):**
→ This was a problem with the old "mint-once-at-startup" wrapper. The new architecture lets `gws mcp` refresh tokens internally, so this should not recur. If it does, verify `credentials.enc` exists in the account dir and run `~/.config/gws/reauth.sh`.

**"Access blocked" during OAuth login:**
→ While the app is in Testing: add the Google account as a test user on the OAuth consent screen (Step 5).

**"This app is blocked" for a Workspace account after publishing:**
→ A Workspace admin must mark that account's OAuth client ID as Trusted (Admin console → Security → Access and data control → API controls → Manage app access). See Step 5.

**API calls fail with "permission denied":**
→ For work accounts on a different domain, grant IAM access (Step 4).

**MCP servers not starting (no error):**
→ For Claude Code: `mcpServers` in `settings.local.json` is silently ignored. Use `.mcp.json` (project root), `~/.claude.json` (global via `claude mcp add --scope user`), or `claude_desktop_config.json` for Claude Desktop.

**Claude Desktop says "I don't have write access" despite write scopes:**
→ Settings → Connectors → disable the built-in Gmail/Drive/Calendar (claude.ai-managed, read-only).

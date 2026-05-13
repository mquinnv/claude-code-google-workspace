# Multi-Account Google Workspace + Slack MCP for Claude Code

Give Claude Code access to Gmail, Google Drive, Calendar, Sheets, Docs, and Slack — with full support for multiple Google accounts (e.g., personal + work).

## Background

Claude Desktop and Claude Cowork have built-in Google Workspace integrations — flip a toggle and you're connected. **Claude Code has nothing.** As of March 2026, there's no official integration, no plugin that handles multi-account, and no documentation on how to set it up.

This repo is the result of ~6 hours of research and debugging to get it working. The final solution is simple, but getting there required discovering several undocumented behaviors in Claude Code's MCP system, Google's OAuth2 implementation, and the `gws` CLI.

### What makes this hard

It's not one problem — it's a stack of them, each undocumented:

1. **Claude Code silently ignores MCP config in the wrong file.** If you put `mcpServers` in `settings.local.json` (where you'd expect it), servers don't start. No error. No log. You can spend hours restarting and re-checking JSON syntax. The config must go in `.mcp.json` at the project root. ([Claude Code Issue #24477](https://github.com/anthropics/claude-code/issues/24477))

2. **One OAuth client for two Google accounts breaks both.** Google invalidates account A's refresh token when you authenticate account B with the same OAuth client. You need separate OAuth Desktop App clients — one per account — in the same GCP project.

3. **`gws mcp` was removed in v0.8.0.** The Google Workspace CLI's MCP server mode (`gws mcp`) only exists in versions ≤0.7.x. Install with `npm install -g @googleworkspace/cli@0.7.0` and pin it — `npm update` will break the setup. If you have Homebrew's `gws` (a different "git workspace" tool) installed, `brew uninstall gws` first.

4. **The credential file env var doesn't work — and neither does the system keyring for multi-account.** `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` doesn't reliably route to the right account. The system keyring (`gws` default) only stores credentials for one account at a time — the last `gws auth login` wins for everyone. The fix is per-account isolated config directories with `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`, so each account has its own encrypted credential store and `gws mcp` can refresh tokens internally with no 1-hour expiry.

4. **Go binaries use single-dash flags.** Both the `gws` CLI and [`slack-mcp-server`](https://github.com/nichochar/slack-mcp-server) are Go binaries. `--transport stdio` fails silently. It's `-t stdio` — or just omit it (stdio is the default).

5. **MCP servers only start at session launch.** Config changes don't take effect until you restart Claude Code entirely.

Each of these individually cost 30-120 minutes to diagnose. Together they make the setup feel broken when it's actually a solvable configuration problem.

### What we tried and rejected

| Approach | Why It Failed |
|----------|--------------|
| Legacy `google-workspace` Claude Code plugin | Single-account only, port 8000 conflict blocks second instance |
| Single OAuth client for both accounts | Google invalidates first account's refresh token on second auth |
| `CREDENTIALS_FILE` env var per MCP server | Doesn't reliably route to the right account (system keyring wins) |
| Mint-one-shot access token via `GOOGLE_WORKSPACE_CLI_TOKEN` | Works for ~1 hour, then token expires and `gws mcp` can't refresh — fatal for Claude Desktop |
| `gws` CLI 0.8.0+ | `gws mcp` subcommand was removed — must pin to 0.7.x |
| `mcpServers` in `settings.local.json` | Silently ignored — Claude Code never reads MCP config from there |
| `mcpServers` in `.claude/settings.json` | Also silently ignored |
| Service account auth | Can't access personal Gmail/Drive without domain-wide delegation |
| Requesting all 85+ OAuth scopes | Google blocks unverified apps requesting too many scopes |

For the full investigation log, see [docs/research-notes.md](docs/research-notes.md).

## The Solution

The working setup uses:

- **[Google Workspace CLI](https://github.com/googleworkspace/cli)** (`gws` v0.7.0 — pinned; `gws mcp` was removed in 0.8.0)
- **Separate OAuth Desktop clients** — one per Google account, in the same GCP project
- **Per-account isolated config directories** — each at `~/.config/gws/accounts/<account>/` with its own `client_secret.json` and file-backed encrypted credential store, via `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`. This lets `gws mcp` refresh access tokens internally — no 1-hour expiry issue.
- **A thin launcher script** — sets the env vars and execs `gws mcp` against the right account dir
- **`.mcp.json` at project root** (or user-scope via `claude mcp add --scope user`, or `~/Library/Application Support/Claude/claude_desktop_config.json` for Claude Desktop)
- **[slack-mcp-server](https://github.com/nichochar/slack-mcp-server)** — Go-based Slack MCP, read-only by default

### What you get

| MCP Server | Capabilities |
|------------|-------------|
| `gws-personal` | Gmail, Drive, Calendar, Sheets, Docs for your personal Google account |
| `gws-work` | Same, for your work Google account (optional) |
| `slack` | Read channels, search messages, browse threads, list users |

Once running, Claude Code can search your email, read Drive files, check your calendar, read/write spreadsheets, and search Slack — all through natural language.

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and working
- [Node.js](https://nodejs.org/) 18+ (for `npx`)
- [Python 3](https://www.python.org/) (for token minting — uses only stdlib)
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) (for enabling APIs and IAM)
- A Google account with Gmail/Drive access
- (Optional) A Slack workspace where you can create an app

### AI-Guided Setup

1. **Clone this repo** and open Claude Code in it:
   ```bash
   git clone https://github.com/YOUR_USERNAME/claude-code-google-workspace.git
   cd claude-code-google-workspace
   claude
   ```

2. **Tell Claude Code**: "Set up Google Workspace MCP for me"

   The `CLAUDE.md` in this repo contains machine-readable setup instructions. Claude Code will walk you through each step, prompting you only for browser-based OAuth steps that can't be automated.

3. **Restart Claude Code** to load the new MCP servers.

### Manual Setup

If you prefer step-by-step instructions: [docs/manual-setup.md](docs/manual-setup.md).

### Full Research Log

To understand every decision and failed approach: [docs/research-notes.md](docs/research-notes.md).

## Architecture

```
Claude Code / Claude Desktop session start
        │
        ├─── reads MCP config (.mcp.json | ~/.claude.json | claude_desktop_config.json)
        │
        ├─── starts gws-personal server:
        │      │
        │      ├── gws-token-wrapper.sh ~/.config/gws/accounts/personal -s ...
        │      │     │
        │      │     └── exec: env GOOGLE_WORKSPACE_CLI_CONFIG_DIR=.../personal \
        │      │                   GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
        │      │                   gws mcp -s gmail,drive,...
        │      │
        │      └── gws mcp ←→ refreshes access tokens internally from credentials.enc
        │                 ←→ Google APIs (Gmail, Drive, Calendar, Sheets, Docs)
        │
        ├─── starts gws-work server:
        │      │
        │      └── (same flow, points at ~/.config/gws/accounts/work)
        │
        └─── starts slack server:
               │
               └── npx slack-mcp-server (SLACK_MCP_XOXP_TOKEN env var)
```

### Why isolated config dirs?

The `gws` CLI defaults to the system keyring for credential storage, and the keyring only holds one set of credentials at a time — the last `gws auth login` wins for every account. With a single shared config dir, calling `gws drive about get` resolves to whoever logged in last, regardless of which `CREDENTIALS_FILE` env var or `client_secret.json` you point at.

By giving each account its own `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` and switching the keyring backend to `file`, each account gets an isolated encrypted credential store (`credentials.enc`) that `gws mcp` can decrypt, refresh, and use independently. No shared state, no contention, no 1-hour expiry — `gws mcp` mints new access tokens internally as needed.

The launcher script is a 5-line shim: it sets the two env vars and execs `gws mcp`.

### Why separate OAuth clients?

OAuth2 Desktop App clients have a behavior where issuing a new refresh token for account B invalidates the existing refresh token for account A — if they share the same `client_id`. Creating separate OAuth Desktop clients in the same GCP project gives each account its own independent token lifecycle.

## Using in Your Own Projects

After setup, you need two things in any project where you want these MCP servers:

1. **`.mcp.json` at the project root** — copy from this repo's template and fill in your paths
2. **`~/.config/gws/`** — credential files + wrapper script (created once during setup, shared across all projects)

Or add the `mcpServers` config to `~/.claude.json` for global access in every project.

**Always gitignore `.mcp.json`** — it contains OAuth tokens.

## Known Gotchas

These are ordered by how much time they'll cost you if you hit them unaware:

| # | Gotcha | Time Cost | Symptom | Fix |
|---|--------|-----------|---------|-----|
| 1 | `mcpServers` in `settings.local.json` is **silently ignored** | 2+ hours | Servers never start, zero errors | Use `.mcp.json` (project root) or `~/.claude.json` (global). [Issue #24477](https://github.com/anthropics/claude-code/issues/24477) |
| 2 | Same OAuth client for two accounts | 1-2 hours | First account stops working after second account authenticates | Create separate OAuth Desktop clients per account |
| 3 | `gws mcp` removed in v0.8.0 | 30 min | `Unknown service 'mcp'` from `gws mcp ...` on any current install | Pin to 0.7.0: `npm install -g @googleworkspace/cli@0.7.0` |
| 4 | System keyring stores only one account's creds | 1 hour | Same data returned for every account, regardless of which MCP is invoked | Use per-account `CONFIG_DIR` + `KEYRING_BACKEND=file` (isolated encrypted credential stores) |
| 5 | Mint-one-shot token approach dies after 1hr | 1 hour | API calls work briefly, then fail with "invalid authentication credentials" — fatal in long-running Claude Desktop | Use the per-account-dir architecture so `gws mcp` can refresh tokens itself |
| 6 | Work account shows "Access blocked" | 30 min | OAuth consent screen blocks non-test users | Add all accounts as test users on OAuth consent screen + grant IAM `serviceUsageConsumer` role |
| 7 | Claude Desktop built-in Google connectors are read-only | 30 min | "I don't have write access" even with our MCPs configured | Settings → Connectors → disable the built-in Gmail/Drive/Calendar |
| 8 | MCP servers only start at session launch | 15 min | Config changes don't take effect | Restart Claude Code / Claude Desktop after MCP config changes |
| 9 | Go binaries use single-dash flags | 15 min | `--transport stdio` fails silently | Use `-t stdio` or omit (stdio is default) |
| 10 | `claude mcp add` collides with inner `-s` flag | 10 min | "Invalid scope" error from `claude mcp add` | Use `--` separator: `claude mcp add NAME -- WRAPPER ARGS -s scopes` |
| 11 | Homebrew `gws` package collides on binary | 10 min | `gws` is on PATH but it's the "git workspace" tool, not Google | `brew uninstall gws` before `npm install -g @googleworkspace/cli@0.7.0` |
| 12 | `gws auth login` opens foreground browser | 5 min | Wrong Chrome profile = wrong account authenticated | Bring correct Chrome profile to front before running |
| 13 | Too many OAuth scopes requested | 10 min | Google blocks unverified app | Use `-s drive,gmail,calendar,sheets,docs` (not all scopes) |
| 14 | `gws auth export` includes "Using keyring backend" prefix line | 5 min | Exported JSON file unparseable | (No longer relevant — the new architecture doesn't use `gws auth export` at all) |

## Caveats

- **Tested with `gws` CLI v0.7.0 and current Claude Code / Claude Desktop**. `gws mcp` was removed in v0.8.0 — the setup will not work on newer `gws` until/unless someone ships a replacement standalone Google Workspace MCP server we can switch to.
- Google and Anthropic will likely make this easier natively — this repo fills the gap until then
- GCP project + OAuth consent screen setup requires manual browser steps (can't be fully automated)
- Tested on macOS — Linux should work, Windows untested
- The `gws` CLI is pre-1.0 — flags and auth behavior may change again

## References

- [Google Workspace CLI](https://github.com/googleworkspace/cli) — the core tool powering Google Workspace access
- [slack-mcp-server](https://github.com/nichochar/slack-mcp-server) — Slack MCP server
- [Claude Code MCP docs](https://docs.anthropic.com/en/docs/claude-code/mcp) — official MCP server documentation
- [MCP Specification](https://modelcontextprotocol.io/) — the Model Context Protocol spec
- [Google OAuth2 documentation](https://developers.google.com/identity/protocols/oauth2) — OAuth flow and token lifecycle
- [Claude Code Issue #24477](https://github.com/anthropics/claude-code/issues/24477) — `settings.local.json` silent ignore bug

## Contributing

Issues and PRs welcome. If you hit a new gotcha, please open an issue — every undocumented behavior we capture saves someone hours.

## License

MIT

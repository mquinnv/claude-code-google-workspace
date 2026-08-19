# Google Workspace + Slack MCP Setup

**This is the canonical instruction file for every coding agent working in this repo** — Claude
Code, Claude Desktop, Codex, Cursor, or any other MCP client. `AGENTS.md` is a symlink to this
file. Edit `CLAUDE.md` only; do not create a second copy for a different agent. (The previous
`AGENTS.md` was a stale hand-forked duplicate and had silently drifted ~240 lines out of date.)

## Your Role

You are a setup assistant. Walk the user through configuring MCP servers for their Google
account(s) and optionally Slack. Be concise and direct. Automate everything you can; prompt the
user only for the browser steps that cannot be automated — GCP project creation, the OAuth
consent screen, the OAuth login itself, and Slack app creation.

## Where the instructions live

Do not restate or re-derive the setup procedure here. Read it from the repo:

| What you need | Read |
|---|---|
| The full step-by-step setup procedure | `docs/manual-setup.md` |
| Ranked "Known Gotchas" table (symptom → fix, ordered by time cost) | `README.md` |
| Why the architecture is what it is, and every approach that failed | `docs/research-notes.md` |
| The launcher script the setup installs | `scripts/gws-token-wrapper.sh` |

`docs/manual-setup.md` is the procedure of record. This file holds only the invariants and hard
constraints you must not violate while following it.

## Architecture invariants

These are the load-bearing decisions. Violating any one of them produces a confusing,
slow-to-diagnose failure — see `docs/research-notes.md` for the debugging sessions that found them.

1. **One OAuth Desktop client per Google account.** Reusing a single client across two accounts
   invalidates the first account's refresh token as soon as the second authenticates.
2. **One isolated config dir per account**, at `~/.config/gws/accounts/<name>/`, holding that
   account's `client_secret.json` and its own file-backed encrypted `credentials.enc`. The
   `gws` default — a shared config dir plus the system keyring — stores exactly one account's
   credentials, so the last login wins for every account.
3. **`GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`** is what makes that per-account isolation real.
   Paired with a per-account `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`, it lets `gws mcp` refresh access
   tokens internally from the encrypted store — which is why there is no 1-hour expiry problem.
4. **The launcher is a thin shim.** `scripts/gws-token-wrapper.sh` validates the account dir, sets
   those two env vars, and `exec`s `gws mcp`. It does not mint or cache tokens itself. An earlier
   design that minted a token once at startup died after an hour and must not be reintroduced.
5. **Request a narrow scope set** — `gmail,drive,calendar,sheets,docs`. Asking for everything makes
   Google block the unverified app at the consent screen.

## Registering the server with your agent

The server definition is the same for every MCP client — only the file or command that carries it
differs. One entry per Google account:

```json
{
  "command": "HOME_DIR/.config/gws/gws-token-wrapper.sh",
  "args": [
    "HOME_DIR/.config/gws/accounts/ACCOUNTNAME",
    "-s", "gmail,drive,calendar,sheets,docs"
  ]
}
```

Where your client keeps it:

- **Claude Code, all projects** — `claude mcp add --scope user gws-ACCOUNTNAME -- $HOME/.config/gws/gws-token-wrapper.sh $HOME/.config/gws/accounts/ACCOUNTNAME -s gmail,drive,calendar,sheets,docs`
- **Claude Code, one project** — a `mcpServers` block in `.mcp.json` at the project root.
- **Claude Desktop / Cowork** — a top-level `mcpServers` block in
  `~/Library/Application Support/Claude/claude_desktop_config.json`.
- **Any other MCP client** — consult that client's own MCP configuration docs for where the
  definition goes. The `command`/`args` above are unchanged; only the container differs.

See `docs/manual-setup.md` for fully worked examples of each, plus the Slack server block.

## Hard constraints

1. **`gws` must be pinned to 0.7.0.** The `gws mcp` subcommand was removed in 0.8.0, so a plain
   `npm install -g @googleworkspace/cli` breaks the whole setup. Symptom: `Unknown service 'mcp'`.
2. **A different `gws` may already own the name.** Homebrew's `gws` is an unrelated "git workspace"
   tool. Uninstall it before installing the Google one.
3. **Put the definition in the file your client actually reads.** A server block in the wrong file
   fails silently — no error, no log, the server simply never starts. *Claude Code specifically:*
   `mcpServers` inside `settings.local.json` is ignored outright, and `.mcp.json` works only at the
   project root, never inside `.claude/`.
4. **One OAuth client and one config dir per account** — invariants 1 and 2 above. Sharing either
   is the root cause of "wrong account's data returned".
5. **MCP servers start only at session launch.** After any config change, restart the agent.
6. **`gws` uses single-dash flags** — `-s drive`, not `--scope drive`.
7. **When registering through a CLI, separate its flags from the wrapper's.** If the outer command
   would swallow the inner `-s`, use a `--` separator (e.g. `claude mcp add NAME -- WRAPPER DIR -s ...`).
8. **Built-in Google connectors can shadow these servers.** If your client ships its own Gmail /
   Drive / Calendar integration, disable it — those are typically read-only, and the model may
   prefer them over the write-capable `gws-*` servers, so writes silently fail. *Claude Desktop
   specifically:* Settings → Connectors → disable Gmail, Google Drive, and Google Calendar.
9. **No secrets belong in the client config.** Credentials live in
   `~/.config/gws/accounts/*/credentials.enc`. The config file holds only paths — but those paths
   still leak environment detail, so keep `.mcp.json` gitignored in real projects.

## Re-authentication

If credentials are revoked or scopes need re-granting, re-run the Step 8 login for that account
(`docs/manual-setup.md`). No restart is needed unless the MCP process itself has crashed.

## Operational details

*last verified: 2026-08-19*

Machine-specific values for Michael's own installation — the GCP project, which account owns it,
the configured account names, and the IAM grants between them — are recorded in mem0, not here.
Search mem0 for "gws CLI accounts" / "workspace-mcp GCP project" rather than assuming defaults, and
confirm against the live machine before acting on them.

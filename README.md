# Claude Code Docker

Run [Claude Code](https://claude.ai/code) in a persistent, sandboxed Docker container. Mount any project directory, attach and detach freely, and keep the container running in the background between sessions.

## Why?

Anthropic provides a [reference devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) designed for VS Code Dev Containers. This project solves a different problem: **running Claude Code headlessly from a terminal with persistent containers you can reconnect to**, supporting multiple named profiles for different accounts/endpoints.

| | Official devcontainer | This project |
|---|---|---|
| **Target** | VS Code Dev Containers | Standalone terminal use |
| **Container lifecycle** | Managed by VS Code | Persistent, managed by `run-claude.sh` |
| **Workspace** | Baked into devcontainer.json | Configurable per-session via conf file |
| **Reconnect** | VS Code handles it | Re-run `./run-claude.sh` to attach |
| **Multiple sessions** | One per window | Named sessions, run in parallel |
| **Multiple profiles** | One identity | Separate conf files per account/endpoint |
| **Auth** | Manual setup | Keychain / auth-token / credentials file / API key |
| **SSH** | Manual setup | Key file / agent forwarding / none |
| **Plugins** | Manual install | Shared via `~/.claude` mount |

---

## ⚠️ Security Warning — Read Before Using

This container is designed to give Claude broad filesystem access for productive development. Understand the trade-offs:

**What the container CAN access (when fully configured):**
- Your **entire home directory** (`/Users/yourname`) — read-write by default when `MOUNT_MAC_HOME=true`
- Your **`_dev` folder** and all projects within it
- Your **SSH keys** (mounted or forwarded via agent)
- Your **AWS credentials** (`~/.aws/`)
- Your **GitHub, GitLab, NPM, Kubernetes, Atlassian** configs and tokens
- **All environment variables** passed by the shell function (API keys, passwords, etc.)

**What the container CANNOT do (firewall-enforced):**
- Make outbound network calls except to: Anthropic API, GitHub, GitLab, plugin marketplace, SSH, and any explicitly added `EXTRA_ALLOWED_DOMAINS`
- Run as root (Claude Code runs as the unprivileged `claude` user)
- Use suid/sgid privilege escalation (bits stripped at startup)

**Key principle:** The firewall limits where data can go, but Claude can still read (and write) sensitive files on your filesystem. Use `MOUNT_MAC_HOME_RO=true` if you want read-only home directory access.

---

## Dual-Profile Setup (PSD + Personal)

This repo includes two conf files for two separate Claude identities. The shell functions in `~/.zshrc-claude-psd` and `~/.zshrc-claude-personal` wire them up as terminal commands.

| | `claude-psd` | `claude-personal` |
|---|---|---|
| **Auth** | `auth-token` → custom endpoint | `keychain` → `claude.ai` |
| **Claude state** | `~/.claude-psd` | `~/.claude-personal` |
| **Conf file** | `claude-docker-psd.conf` | `claude-docker-personal.conf` |
| **Container name** | `claude-psd` | `claude-personal` |
| **Filesystem access** | Same as personal | Same as PSD |

Both profiles mount identical filesystem paths — they differ only in credentials and Claude state directory. This means Claude sees the same files regardless of which profile you use.

### Shell Commands

```bash
# Start PSD/work session (uses custom endpoint)
claude-psd

# Start personal session (uses claude.ai keychain credentials)
claude-personal

# Force-recreate container (picks up latest conf, fixes stale mounts)
claude-psd --fresh
claude-personal --fresh

# Named session (custom container name)
claude-psd my-project
claude-personal my-project

# Override workspace for this session
claude-psd my-project --work-dir ~/Documents/_dev/amver-cli

# Update a specific profile's image (no-cache rebuild)
claude-psd-update
claude-personal-update
```

The `--fresh` flag stops any existing container before starting, ensuring the latest conf settings and mount configuration are applied. Use this whenever you update a conf file or can't see expected files.

---

## Quick Start (Generic)

```bash
# 1. Clone
git clone <this-repo>
cd claude-code-docker

# 2. Configure
cp claude-docker.conf.example claude-docker.conf
# Edit claude-docker.conf with your settings

# 3. Run
./run-claude.sh
```

---

## Usage

```bash
# Start in current directory (default session name)
./run-claude.sh

# Named session — mounts $PWD as workspace
./run-claude.sh my-project

# Override workspace directory
./run-claude.sh my-project --work-dir ~/other/repo

# Pass args to claude
./run-claude.sh my-project --model opus

# List running sessions
./run-claude.sh list

# Stop a named session
./run-claude.sh stop my-project

# Stop all sessions
./run-claude.sh stop-all
```

When you Ctrl+C or close your terminal, only the Claude process exits. The container keeps running. Re-run the same command to attach a fresh Claude session to the existing container — no rebuild, no re-setup.

---

## Configuration

All configuration lives in a `.conf` file (gitignored). See `claude-docker.conf.example` for all options. The conf file is sourced as a shell script, so you can use `$HOME` and other variables.

### Authentication Methods

| Method | `AUTH_METHOD` value | When to use |
|--------|---------------------|-------------|
| macOS Keychain | `keychain` | Default for claude.ai OAuth on macOS |
| Auth token | `auth-token` | Custom endpoints (e.g. PSD's LiteLLM proxy) |
| Credentials file | `file` | Linux / CI — point to `.credentials.json` on disk |
| API key | `api-key` | Direct Anthropic API key |

For `auth-token`, set `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` as environment variables before calling `run-claude.sh`. The shell function for the custom endpoint profile does this automatically.

### SSH for Git

| Method | `SSH_METHOD` value | When to use |
|--------|---------------------|-------------|
| Key file | `key-file` | Mount a specific private key (default) |
| Agent | `agent` | Forward your running `ssh-agent` into the container |
| None | `none` | HTTPS for git only, no SSH |

### Workspace & Filesystem Mounts

| Option | Default | Description |
|--------|---------|-------------|
| `WORKSPACE_DIR` | `$PWD` | Mounted at `/workspace` — the primary project directory |
| `DEV_ROOT` | _(unset)_ | If set, mounts your entire `_dev` tree at `/_dev` for cross-project access |
| `MOUNT_MAC_HOME` | `false` | Mounts `$HOME` at its real macOS path inside the container |
| `MOUNT_MAC_HOME_RO` | `false` | If `true`, the home directory mount is read-only |

**Example (from `claude-docker-psd.conf`):**
```bash
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Documents/_dev}"
DEV_ROOT="$HOME/Documents/_dev"
MOUNT_MAC_HOME=true
```

With `MOUNT_MAC_HOME=true`, paths like `/Users/yourname/.zshrc` resolve correctly inside the container because the real macOS directory is volume-mounted at that same path.

### Claude State Directory

Each profile uses its own state directory, set via `CLAUDE_STATE_DIR` in the shell function:

| Profile | State dir | Mounted at |
|---------|-----------|------------|
| `claude-psd` | `~/.claude-psd` | `/home/claude/.claude` |
| `claude-personal` | `~/.claude-personal` | `/home/claude/.claude` |

This keeps credentials, plugins, session history, and settings fully isolated between profiles. Each state directory needs its own `settings.json` — copy `settings.json.example` into each one and customize as needed.

> **Important:** The container's `/home/claude/.claude` always maps to `CLAUDE_STATE_DIR`, never to `~/.claude`. If you edit `~/.claude/settings.json` on the Mac, it won't affect Docker sessions that use profile-specific state dirs.

### Auto-Forwarded Credentials

The following are detected on your host and forwarded automatically — no configuration needed:

| Host path | How it's forwarded |
|-----------|-------------------|
| `~/.aws/` | Copied to `/home/claude/.aws/` (creds/config set to 600) |
| `~/.config/gh/` | Copied to `/home/claude/.config/gh/` |
| `~/.config/glab-cli/` | Copied to `/home/claude/.config/glab-cli/` |
| `~/.gitlab-creds` | Copied to `/home/claude/.gitlab-creds` (600) |
| `~/.npmrc` | Copied to `/home/claude/.npmrc` (600) |
| `~/.kube/` | Copied to `/home/claude/.kube/` (config set to 600) |
| `~/.config/atlassian/` | Copied to `/home/claude/.config/atlassian/` |
| `~/.config/jira/` | Copied to `/home/claude/.config/jira/` |
| `~/.atlassian-creds` | Copied to `/home/claude/.atlassian-creds` (600) |
| `gh auth token` | Passed as `GH_TOKEN` env var |
| `GITLAB_ACCESS_TOKEN` | Forwarded from shell env |
| `ATLASSIAN_API_TOKEN` | Forwarded from shell env |

Credentials are staged read-only at `/mnt/` and copied by `entrypoint.sh` so the `claude` user owns them with correct permissions.

### Additional Domains (Firewall)

The firewall allowlist includes: Anthropic API, GitHub, GitLab (PSD instance), plugin marketplace, npm, PyPI, AWS STS, Atlassian auth, and SSH (port 22).

To add more:
```bash
EXTRA_ALLOWED_DOMAINS="yourco.atlassian.net bitbucket.org"
```

---

## Recommended `settings.json`

```json
{
  "alwaysThinkingEnabled": true,
  "statusLine": {
    "type": "command",
    "command": "/Users/yourname/Documents/_dev/misc/claude-code-docker/statusline.sh",
    "padding": 0
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "SHIPYARD_TEAMS_ENABLED": "true"
  }
}
```

| Setting | What it does |
|---------|-------------|
| `alwaysThinkingEnabled` | Extended thinking on every response |
| `statusLine` | Rich status bar: context usage, cost, burn rate, git branch, session time |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Multiple Claude sessions coordinating via shared task list |
| `SHIPYARD_TEAMS_ENABLED` | Enables Shipyard plugin team features |

### Status Line

A `statusline.sh` script is included in this repo. Point the `statusLine.command` directly at it using the full Mac path — no copying needed. The path resolves inside the container because `MOUNT_MAC_HOME=true` mounts your home directory at its real macOS path.

```json
"statusLine": {
  "type": "command",
  "command": "/Users/yourname/Documents/_dev/misc/claude-code-docker/statusline.sh",
  "padding": 0
}
```

Set this in **every profile's state directory** (e.g. `~/.claude-psd/settings.json`, `~/.claude-personal/settings.json`). Each profile has its own `settings.json` — the statusline command must be set in each one.

> **Do not copy `statusline.sh` to `~/.claude/statusline.sh`.** Pointing directly at the repo means updates to the script take effect immediately without re-copying.

Requires `jq`. Rate limit data comes from Claude Code's native `rate_limits` field (v2.1.80+).

---

## How It Works

```
run-claude.sh
├── Sources .conf file
├── Resolves auth (keychain / auth-token / file / api-key)
├── Resolves SSH (key-file / agent / none)
├── Detects and stages credential files
├── If container already running → docker exec (attach)
├── If container stopped → docker rm, then docker run (detached)
│   └── entrypoint.sh (runs as root)
│       ├── init-firewall.sh — iptables allowlist
│       ├── Strip suid/sgid bits
│       ├── Fix ownership on mounted dirs
│       ├── Symlink host paths so macOS absolute paths resolve
│       ├── Copy staged credentials → correct home locations
│       ├── Configure SSH (key-file or agent)
│       ├── Write .claude.json (skip onboarding)
│       ├── touch /tmp/.claude-ready
│       └── sleep infinity (keeps container alive)
└── run-claude.sh polls for .claude-ready, then:
    └── docker exec -it — runs Claude Code as non-root `claude` user
```

---

## Security Model

| Layer | What it does |
|-------|-------------|
| **iptables firewall** | Blocks all outbound traffic except allowlisted domains/IPs. Enforced at container startup by `init-firewall.sh`. |
| **Non-root execution** | Claude Code runs as the `claude` user. `entrypoint.sh` runs as root only for firewall + setup, then `sleep infinity`. |
| **suid/sgid stripping** | All suid/sgid bits stripped after firewall setup — prevents privilege escalation inside the container. |
| **Read-only credential staging** | Credential files are mounted at `/mnt/` read-only and copied by root — the `claude` user can't write back to host credential locations directly. |
| **Home directory access** | `MOUNT_MAC_HOME=true` mounts `$HOME` read-write by default. This is intentional for full filesystem access. Use `MOUNT_MAC_HOME_RO=true` for read-only. |

**Bottom line:** The container is firewalled and unprivileged. Claude can read/write your filesystem broadly (that's the point), but it can't exfiltrate data to arbitrary hosts.

---

## Requirements

- Docker Desktop
- macOS (primary supported host — keychain auth and `gh` token extraction are macOS-specific)
- Claude Code account (OAuth login on host for keychain method, or API/auth-token key)
- `ssh-agent` running if using `SSH_METHOD=agent`

> **Linux hosts:** Possible using `AUTH_METHOD=file` or `api-key`, with `GH_TOKEN` set manually. Not tested.

---

## License

MIT

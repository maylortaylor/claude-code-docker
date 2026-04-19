# CLAUDE.md — claude-code-docker

This project provides the Docker infrastructure for running Claude Code in isolated, persistent containers. It supports multiple named profiles (PSD and personal) with separate credentials but identical filesystem access.

## What This Project Does

`run-claude.sh` builds a Docker image, starts a named detached container, waits for setup to complete, then attaches an interactive Claude Code session via `docker exec`. If the container is already running, it attaches directly without rebuilding.

The shell functions `claude-psd` and `claude-personal` (defined in `~/.zshrc-claude-psd` and `~/.zshrc-claude-personal`) are the primary entry points — they set the appropriate credentials and call `run-claude.sh`.

## File Structure

| File | Purpose |
|------|---------|
| `run-claude.sh` | Main launcher — resolves auth, SSH, mounts, starts/attaches container |
| `Dockerfile` | Container image — Node 22 slim + Claude Code + tools |
| `entrypoint.sh` | Container init — firewall, credential staging, SSH setup, ownership fixes |
| `init-firewall.sh` | iptables allowlist — runs at container startup as root |
| `claude-docker-psd.conf` | PSD profile config — `auth-token`, PSD workspace, `MOUNT_MAC_HOME=true` |
| `claude-docker-personal.conf` | Personal profile config — `keychain`, personal workspace, `MOUNT_MAC_HOME=true` |
| `claude-docker.conf.example` | Template for new conf files |
| `statusline.sh` | Claude Code status bar script (copy to `~/.claude/statusline.sh`) |
| `settings.json.example` | Recommended `~/.claude/settings.json` |
| `~/.zshrc-claude-psd` | Shell function: `claude-psd` and `claude-psd-update` |
| `~/.zshrc-claude-personal` | Shell function: `claude-personal` and `claude-personal-update` |

## Dual-Profile Architecture

Both profiles are identical in filesystem visibility. They differ only in auth and Claude state:

```
claude-psd()                           claude-personal()
  ├── AUTH_METHOD=auth-token              ├── AUTH_METHOD=keychain
  ├── ANTHROPIC_BASE_URL=custom endpoint   ├── (uses claude.ai keychain creds)
  ├── CLAUDE_STATE_DIR=~/.claude-psd      ├── CLAUDE_STATE_DIR=~/.claude-personal
  └── conf: claude-docker-psd.conf        └── conf: claude-docker-personal.conf

Both mount:
  - $HOME → $HOME (MOUNT_MAC_HOME=true, read-write)
  - $HOME/Documents/_dev → /_dev (DEV_ROOT)
  - /workspace → WORKSPACE_DIR (default: $HOME/Documents/_dev)
  - ~/.claude-{psd|personal} → /home/claude/.claude
  - All detected credential dirs (~/.aws, ~/.config/gh, etc.)
```

## What the Container Can See

**Full home directory** — `/Users/yourname` is bind-mounted at the same path inside the container when `MOUNT_MAC_HOME=true`. Claude can read and write all files there, including `.zshrc`, `.ssh/`, and any file in `~/Documents/_dev/`.

**Cross-project access** — `DEV_ROOT=$HOME/Documents/_dev` mounts the entire `_dev` tree at `/_dev`. The entrypoint also symlinks the real macOS path so absolute paths like `/Users/yourname/Documents/_dev/...` resolve correctly inside the container.

**Credentials forwarded automatically:**
- `~/.aws/` — AWS credentials and config
- `~/.config/gh/` — GitHub CLI config
- `~/.config/glab-cli/` — glab CLI config
- `~/.gitlab-creds` — GitLab credentials file
- `~/.npmrc` — NPM token
- `~/.kube/` — Kubernetes config
- `~/.config/atlassian/`, `~/.atlassian-creds` — Atlassian/Jira
- `GH_TOKEN` — extracted from `gh auth token`
- `GITLAB_ACCESS_TOKEN`, `ATLASSIAN_API_TOKEN` — forwarded from shell env

## Security Model

- **Firewall**: `init-firewall.sh` sets iptables rules that block all outbound traffic except the allowlist (Anthropic API, GitHub, GitLab, npm, SSH, etc.). `EXTRA_ALLOWED_DOMAINS` extends this.
- **Non-root**: Claude Code runs as the unprivileged `claude` user. Root is used only by `entrypoint.sh` during startup.
- **suid/sgid stripped**: After firewall setup, all suid/sgid bits are removed to prevent privilege escalation.
- **Credential staging**: Host credentials are mounted read-only at `/mnt/` and copied to the correct home locations by root — the `claude` user cannot write back to host-side credential paths directly.
- **Home directory write access**: With `MOUNT_MAC_HOME=true` (default for both profiles), Claude has read-write access to `$HOME`. This is intentional. Set `MOUNT_MAC_HOME_RO=true` in the conf file to restrict to read-only.

## Common Tasks

### Add a new allowed domain to the firewall

Edit `claude-docker-psd.conf` or `claude-docker-personal.conf`:
```bash
EXTRA_ALLOWED_DOMAINS="newdomain.com another.io"
```
Then restart with `--fresh` to apply: `claude-psd --fresh`

### Force a fresh container (pick up new conf settings)

```bash
claude-psd --fresh
claude-personal --fresh
```

This stops the existing container (`docker rm -f`) before starting a new one.

### Rebuild the Docker image from scratch

```bash
claude-psd-update      # stops container, rebuilds image with --no-cache
claude-personal-update
```

### Add a new credential type

1. In `run-claude.sh`: add detection logic in the "Additional credential mounts" section, using the same staging pattern (`-v "$HOME/.foo:/mnt/host-foo:ro"`)
2. In `entrypoint.sh`: add the corresponding copy block in the credential staging section, setting correct ownership and permissions
3. Run `claude-psd-update` to rebuild the image

### Change the workspace for one session

```bash
claude-psd my-session --work-dir ~/Documents/_dev/amver-cli
```

The `WORKSPACE_DIR` in the conf is the default; `--work-dir` overrides it for that session only.

## Do Not

- **Do not commit `.conf` files** — they are gitignored and may contain tokens or paths
- **Do not hardcode credentials** in `run-claude.sh`, `Dockerfile`, or `entrypoint.sh`
- **Do not bypass the firewall** by modifying `init-firewall.sh` without understanding the implications — the firewall is the primary network isolation mechanism
- **Do not run the container as root** — the `claude` user must remain unprivileged

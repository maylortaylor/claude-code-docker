#!/bin/bash
# Build and run Claude Code in Docker with configurable workspace, auth, and SSH.
# Container runs detached — re-run this script to attach a new Claude session.
#
# Usage:
#   ./run-claude.sh                                  # session "default", mounts $PWD
#   ./run-claude.sh my-project                       # named session, mounts $PWD
#   ./run-claude.sh my-project --work-dir ~/repo     # override workspace
#   ./run-claude.sh my-project --model opus          # pass args to claude
#   ./run-claude.sh my-project --image ghcr.io/...   # override docker image
#   ./run-claude.sh list                             # show running sessions
#   ./run-claude.sh stop my-project                  # stop a session
#   ./run-claude.sh stop-all                         # stop all sessions

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Subcommands ──────────────────────────────────────────────────
case "${1:-}" in
  list|ls)
    echo "Running Claude sessions:"
    docker ps --filter "name=claude-" --format "  {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null || true
    exit 0
    ;;
  stop)
    target="${2:?Usage: $0 stop <session-name>}"
    docker rm -f "claude-${target}" 2>/dev/null && echo "Stopped claude-${target}" || echo "No session named '${target}'"
    exit 0
    ;;
  stop-all)
    docker ps -q --filter "name=claude-" | xargs -r docker rm -f
    echo "All Claude sessions stopped."
    exit 0
    ;;
esac

# ── Session name (first arg) ────────────────────────────────────
SESSION_NAME="${1:-default}"
shift 2>/dev/null || true

# ── Parse --work-dir flag ────────────────────────────────────────
WORKSPACE_OVERRIDE=""
CLAUDE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir)
      WORKSPACE_OVERRIDE="$(cd "$2" && pwd)"
      shift 2
      ;;
    --image)
      IMAGE_NAME="$2"
      shift 2
      ;;
    *)
      CLAUDE_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"

CONF="${CLAUDE_DOCKER_CONF:-$SCRIPT_DIR/claude-docker.conf}"
if [ -f "$CONF" ]; then
  source "$CONF"
fi

# ── Defaults ─────────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-claude-code}"
AUTH_METHOD="${AUTH_METHOD:-keychain}"
SSH_METHOD="${SSH_METHOD:-key-file}"
CLAUDE_DIR="${CLAUDE_STATE_DIR:-$HOME/.claude}"

# ── Resolve workspace: override > conf > $PWD ────────────────────
if [ -n "$WORKSPACE_OVERRIDE" ]; then
  WORKSPACE_DIR="$WORKSPACE_OVERRIDE"
elif [ -z "${WORKSPACE_DIR:-}" ]; then
  WORKSPACE_DIR="$PWD"
fi

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "ERROR: Workspace does not exist: $WORKSPACE_DIR"
  exit 1
fi

# ── Resolve credentials ─────────────────────────────────────────
CREDS_FILE=""
EXTRA_ENV=()

case "$AUTH_METHOD" in
  keychain)
    if ! command -v security &>/dev/null; then
      echo "ERROR: AUTH_METHOD=keychain but 'security' command not found (not macOS?)."
      exit 1
    fi
    KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-$(whoami)}"
    CREDS=$(security find-generic-password -s "Claude Code-credentials" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)
    if [ -z "$CREDS" ]; then
      echo "ERROR: Could not read credentials from keychain for account '$KEYCHAIN_ACCOUNT'."
      echo "Make sure you're logged in via 'claude' on the host first."
      exit 1
    fi
    CREDS_FILE=$(mktemp)
    echo "$CREDS" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    ;;
  file)
    CREDENTIALS_FILE="${CREDENTIALS_FILE:?Set CREDENTIALS_FILE in claude-docker.conf}"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
      echo "ERROR: CREDENTIALS_FILE does not exist: $CREDENTIALS_FILE"
      exit 1
    fi
    CREDS_FILE="$CREDENTIALS_FILE"
    ;;
  api-key)
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY in claude-docker.conf}"
    EXTRA_ENV+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    ;;
  auth-token)
    # Auth handled entirely via ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL env vars.
    # Both are forwarded in the env-var block above — nothing to mount here.
    ;;
  *)
    echo "ERROR: Unknown AUTH_METHOD '$AUTH_METHOD'. Use: keychain, file, or api-key."
    exit 1
    ;;
esac

# ── Resolve SSH ──────────────────────────────────────────────────
SSH_ARGS=()

case "$SSH_METHOD" in
  key-file)
    if [ -z "${SSH_KEY_PATH:-}" ]; then
      for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
        if [ -f "$key" ]; then
          SSH_KEY_PATH="$key"
          break
        fi
      done
    fi
    if [ -z "${SSH_KEY_PATH:-}" ] || [ ! -f "$SSH_KEY_PATH" ]; then
      echo "ERROR: No SSH key found. Set SSH_KEY_PATH or use SSH_METHOD=none."
      exit 1
    fi
    SSH_ARGS+=(-v "$SSH_KEY_PATH:/home/claude/.ssh/user_key:ro")
    SSH_ARGS+=(-e "SSH_METHOD=key-file")
    ;;
  agent)
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
      echo "ERROR: SSH_METHOD=agent but SSH_AUTH_SOCK is not set. Is ssh-agent running?"
      exit 1
    fi
    SSH_ARGS+=(-v "$SSH_AUTH_SOCK:/run/ssh-agent.sock")
    SSH_ARGS+=(-e "SSH_AUTH_SOCK=/run/ssh-agent.sock")
    SSH_ARGS+=(-e "SSH_METHOD=agent")
    ;;
  none)
    SSH_ARGS+=(-e "SSH_METHOD=none")
    ;;
  *)
    echo "ERROR: Unknown SSH_METHOD '$SSH_METHOD'. Use: key-file, agent, or none."
    exit 1
    ;;
esac

# ── Pass extra allowed domains to firewall ───────────────────────
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
  EXTRA_ENV+=(-e "EXTRA_ALLOWED_DOMAINS=$EXTRA_ALLOWED_DOMAINS")
fi

# ── Additional credential mounts ──────────────────────────────────
# Each is staged under /mnt/ read-only; entrypoint.sh copies them to
# the correct home-directory location and fixes ownership/permissions.
ADDITIONAL_CRED_ARGS=()

# GitLab credentials file (~/.gitlab-creds)
if [ -f "$HOME/.gitlab-creds" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.gitlab-creds:/mnt/gitlab-creds:ro")
fi

# glab CLI config (~/.config/glab-cli/)
if [ -d "$HOME/.config/glab-cli" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.config/glab-cli:/mnt/host-glab-config:ro")
fi

# AWS credentials (~/.aws/)
if [ -d "$HOME/.aws" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.aws:/mnt/host-aws:ro")
fi

# GitHub CLI full config (~/.config/gh/)
# GH_TOKEN env var above handles basic auth; this adds the full gh config
# so commands like `gh api` and `gh pr` work without re-authenticating.
if [ -d "$HOME/.config/gh" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.config/gh:/mnt/host-gh-config:ro")
fi

# NPM credentials (~/.npmrc)
if [ -f "$HOME/.npmrc" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.npmrc:/mnt/host-npmrc:ro")
fi

# Kubernetes config (~/.kube/)
if [ -d "$HOME/.kube" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.kube:/mnt/host-kube:ro")
fi

# Atlassian CLI config (~/.config/atlassian/) — covers `atlas` CLI
if [ -d "$HOME/.config/atlassian" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.config/atlassian:/mnt/host-atlassian:ro")
fi

# Jira CLI config (~/.config/jira/) — covers go-jira and similar
if [ -d "$HOME/.config/jira" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.config/jira:/mnt/host-jira-config:ro")
fi

# Atlassian creds file (~/.atlassian-creds) — sets ATLASSIAN_EMAIL and ATLASSIAN_API_TOKEN
if [ -f "$HOME/.atlassian-creds" ]; then
  ADDITIONAL_CRED_ARGS+=(-v "$HOME/.atlassian-creds:/mnt/host-atlassian-creds:ro")
fi

# Atlassian API token — forward from host shell if set
if [ -n "${ATLASSIAN_API_TOKEN:-}" ]; then
  EXTRA_ENV+=(-e "ATLASSIAN_API_TOKEN=$ATLASSIAN_API_TOKEN")
fi

# ── Forward GitLab credentials from host shell ───────────────────
[ -n "${GITLAB_ACCESS_TOKEN:-}" ] && EXTRA_ENV+=(-e "GITLAB_ACCESS_TOKEN=$GITLAB_ACCESS_TOKEN")
[ -n "${GITLAB_USERNAME:-}" ]     && EXTRA_ENV+=(-e "GITLAB_USERNAME=$GITLAB_USERNAME")
[ -n "${GITLAB_URL:-}" ]          && EXTRA_ENV+=(-e "GITLAB_URL=$GITLAB_URL")

# ── Forward Atlassian credentials from host shell ────────────────
[ -n "${ATLASSIAN_EMAIL:-}" ]     && EXTRA_ENV+=(-e "ATLASSIAN_EMAIL=$ATLASSIAN_EMAIL")
[ -n "${ATLASSIAN_API_TOKEN:-}" ] && EXTRA_ENV+=(-e "ATLASSIAN_API_TOKEN=$ATLASSIAN_API_TOKEN")

# ── Forward Anthropic proxy vars (PSD / custom-endpoint setups) ──
# These are set by claude-psd() in .zshrc-claude-psd and must reach the container.
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]           && EXTRA_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_AUTH_TOKEN")
[ -n "${ANTHROPIC_BASE_URL:-}" ]             && EXTRA_ENV+=(-e "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL")
[ -n "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ]   && EXTRA_ENV+=(-e "ANTHROPIC_DEFAULT_OPUS_MODEL=$ANTHROPIC_DEFAULT_OPUS_MODEL")
[ -n "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ] && EXTRA_ENV+=(-e "ANTHROPIC_DEFAULT_SONNET_MODEL=$ANTHROPIC_DEFAULT_SONNET_MODEL")
[ -n "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ]  && EXTRA_ENV+=(-e "ANTHROPIC_DEFAULT_HAIKU_MODEL=$ANTHROPIC_DEFAULT_HAIKU_MODEL")

# ── Mount full _dev tree for cross-project access ────────────────
# Mounts $DEV_ROOT at /_dev (read-only) so Claude can navigate the
# full _dev tree even when /workspace is a specific project subdir.
DEV_ROOT_ARGS=()
if [ -n "${DEV_ROOT:-}" ] && [ -d "$DEV_ROOT" ]; then
  REAL_DEV_ROOT=$(cd "$DEV_ROOT" && pwd)
  DEV_ROOT_ARGS+=(-e "HOST_DEV_PATH=$DEV_ROOT")
  # Always mount at /_dev — even when workspace IS the dev root.
  # entrypoint.sh symlinks the macOS absolute path → /_dev so that
  # hardcoded paths like /Users/yourname/Documents/_dev/... resolve inside the container.
  DEV_ROOT_ARGS+=(-v "$REAL_DEV_ROOT:/_dev")
fi

# ── Mount Mac home directory ──────────────────────────────────────
# Mounts $HOME at its real Mac path inside the container so dotfiles
# like ~/.zshrc, ~/.ssh/config, etc. are accessible by Claude.
# Controlled by MOUNT_MAC_HOME=true in your .conf file.
# Set MOUNT_MAC_HOME_RO=true to mount read-only (default is read-write).
MAC_HOME_ARGS=()
if [ "${MOUNT_MAC_HOME:-false}" = "true" ] && [ -n "$HOME" ]; then
  if [ "${MOUNT_MAC_HOME_RO:-false}" = "true" ]; then
    MAC_HOME_ARGS+=(-v "$HOME:$HOME:ro")
  else
    MAC_HOME_ARGS+=(-v "$HOME:$HOME")
  fi
fi

# ── Build or Pull ────────────────────────────────────────────────
if [[ "$IMAGE_NAME" == */* ]]; then
  docker pull "$IMAGE_NAME"
else
  docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
fi

# ── Claude state mount ──────────────────────────────────────────
# Mount the entire ~/.claude directory so all state carries over:
# credentials, settings, statsig, onboarding, session history, etc.
CLAUDE_STATE_ARGS=()
if [ -d "$CLAUDE_DIR" ]; then
  CLAUDE_STATE_ARGS+=(-v "$CLAUDE_DIR:/home/claude/.claude")
fi

# Mount credentials read-only — entrypoint copies so Claude can refresh tokens
CRED_ARGS=()
if [ -n "$CREDS_FILE" ]; then
  CRED_ARGS+=(-v "$CREDS_FILE:/mnt/host-credentials.json:ro")
fi

# Extract gh token from keyring and pass as env var (file has no token on macOS)
GH_ARGS=()
if command -v gh &>/dev/null; then
  GH_TOKEN=$(gh auth token 2>/dev/null)
  if [ -n "$GH_TOKEN" ]; then
    GH_ARGS+=(-e "GH_TOKEN=$GH_TOKEN")
  fi
fi

# ── Container name ───────────────────────────────────────────────
CONTAINER_NAME="claude-${SESSION_NAME}"

# ── Reconnect if container is already running ────────────────────
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  if [ -n "$WORKSPACE_OVERRIDE" ]; then
    echo "WARN: Container '$SESSION_NAME' is already running. Workspace override ignored."
    echo "      Stop it first to change workspace: $0 stop $SESSION_NAME"
  fi
  echo "Attaching to existing container '$SESSION_NAME'..."
  exec docker exec -it "$CONTAINER_NAME" gosu claude claude --dangerously-skip-permissions "$@"
fi

# Clean up any stopped container with the same name
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# ── Run ──────────────────────────────────────────────────────────
docker run -d \
  --name "$CONTAINER_NAME" \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  -e "HOST_HOME=$HOME" \
  -e "TZ=$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')" \
  -v /etc/localtime:/etc/localtime:ro \
  "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
  "${SSH_ARGS[@]+"${SSH_ARGS[@]}"}" \
  "${CLAUDE_STATE_ARGS[@]+"${CLAUDE_STATE_ARGS[@]}"}" \
  "${CRED_ARGS[@]+"${CRED_ARGS[@]}"}" \
  "${GH_ARGS[@]+"${GH_ARGS[@]}"}" \
  "${ADDITIONAL_CRED_ARGS[@]+"${ADDITIONAL_CRED_ARGS[@]}"}" \
  "${DEV_ROOT_ARGS[@]+"${DEV_ROOT_ARGS[@]}"}" \
  "${MAC_HOME_ARGS[@]+"${MAC_HOME_ARGS[@]}"}" \
  -v "$WORKSPACE_DIR:/workspace" \
  "$IMAGE_NAME"

# Wait for setup (firewall, plugins) to finish
echo "Container started. Waiting for setup..."
for i in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" test -f /tmp/.claude-ready 2>/dev/null; then
    echo "Attaching..."
    exec docker exec -it "$CONTAINER_NAME" gosu claude claude --dangerously-skip-permissions "$@"
  fi
  sleep 1
done
echo "ERROR: Container setup did not complete within 60s. Check: docker logs $CONTAINER_NAME"
exit 1

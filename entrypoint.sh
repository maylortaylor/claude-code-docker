#!/bin/bash
set -e

# Run firewall setup as root
/usr/local/bin/init-firewall.sh

# Remove suid/sgid binaries so claude user can't escalate
echo "Stripping suid/sgid bits..."
find /usr /bin /sbin -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Fix ownership on mounted directories so claude user can read/write them
chown -R claude:claude /home/claude/.claude 2>/dev/null || true
chown -R claude:claude /workspace 2>/dev/null || true

# Symlink host user's home path so plugin absolute paths resolve inside container.
# Marketplace configs store the host's absolute path (e.g. /Users/cdowin/.claude/...)
# which doesn't exist in the container where ~/.claude is at /home/claude/.claude.
HOST_HOME="${HOST_HOME:-}"
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/claude" ]; then
  if [ -d "$HOST_HOME" ] && [ ! -L "$HOST_HOME" ]; then
    # Real Mac home is volume-mounted — skip symlink to avoid conflict.
    # Absolute paths like /Users/yourname/.claude resolve via the mount.
    :
  else
    mkdir -p "$(dirname "$HOST_HOME")"
    ln -sfn /home/claude "$HOST_HOME"
  fi
fi

# Symlink host _dev path so absolute macOS paths resolve inside container.
HOST_DEV_PATH="${HOST_DEV_PATH:-}"
if [ -n "$HOST_DEV_PATH" ]; then
  if [ -d "$HOST_DEV_PATH" ] && [ ! -L "$HOST_DEV_PATH" ]; then
    # Real directory exists (e.g. MOUNT_MAC_HOME=true) — no symlink needed.
    :
  else
    mkdir -p "$(dirname "$HOST_DEV_PATH")"
    if [ -d "/_dev" ]; then
      ln -sfn /_dev "$HOST_DEV_PATH"
    elif [ -d "/workspace" ]; then
      ln -sfn /workspace "$HOST_DEV_PATH"
    fi
  fi
fi

# Copy credentials extracted from host keychain (overwrites mounted version)
if [ -f /mnt/host-credentials.json ]; then
  cp /mnt/host-credentials.json /home/claude/.claude/.credentials.json
  chmod 600 /home/claude/.claude/.credentials.json
  chown claude:claude /home/claude/.claude/.credentials.json
fi

# ── Copy additional credentials from /mnt/ staging area ────────────
# run-claude.sh mounts these read-only; we copy so claude user owns them
# and permissions are correct for each credential type.

# GitLab credentials file (~/.gitlab-creds)
if [ -f /mnt/gitlab-creds ]; then
  cp /mnt/gitlab-creds /home/claude/.gitlab-creds
  chmod 600 /home/claude/.gitlab-creds
  chown claude:claude /home/claude/.gitlab-creds
fi

# glab CLI config (~/.config/glab-cli/)
if [ -d /mnt/host-glab-config ]; then
  mkdir -p /home/claude/.config/glab-cli
  cp -r /mnt/host-glab-config/. /home/claude/.config/glab-cli/
  chown -R claude:claude /home/claude/.config/glab-cli
fi

# AWS credentials (~/.aws/)
if [ -d /mnt/host-aws ]; then
  mkdir -p /home/claude/.aws
  cp -r /mnt/host-aws/. /home/claude/.aws/
  chmod 600 /home/claude/.aws/credentials 2>/dev/null || true
  chmod 600 /home/claude/.aws/config 2>/dev/null || true
  chown -R claude:claude /home/claude/.aws
fi

# GitHub CLI full config (~/.config/gh/)
if [ -d /mnt/host-gh-config ]; then
  mkdir -p /home/claude/.config/gh
  cp -r /mnt/host-gh-config/. /home/claude/.config/gh/
  chown -R claude:claude /home/claude/.config/gh
fi

# NPM credentials (~/.npmrc)
if [ -f /mnt/host-npmrc ]; then
  cp /mnt/host-npmrc /home/claude/.npmrc
  chmod 600 /home/claude/.npmrc
  chown claude:claude /home/claude/.npmrc
fi

# Kubernetes config (~/.kube/)
if [ -d /mnt/host-kube ]; then
  mkdir -p /home/claude/.kube
  cp -r /mnt/host-kube/. /home/claude/.kube/
  chmod 600 /home/claude/.kube/config 2>/dev/null || true
  chown -R claude:claude /home/claude/.kube
fi

# Atlassian CLI config (~/.config/atlassian/)
if [ -d /mnt/host-atlassian ]; then
  mkdir -p /home/claude/.config/atlassian
  cp -r /mnt/host-atlassian/. /home/claude/.config/atlassian/
  chown -R claude:claude /home/claude/.config/atlassian
fi

# Jira CLI config (~/.config/jira/)
if [ -d /mnt/host-jira-config ]; then
  mkdir -p /home/claude/.config/jira
  cp -r /mnt/host-jira-config/. /home/claude/.config/jira/
  chown -R claude:claude /home/claude/.config/jira
fi

# Atlassian creds file (~/.atlassian-creds) — sets ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN
if [ -f /mnt/host-atlassian-creds ]; then
  cp /mnt/host-atlassian-creds /home/claude/.atlassian-creds
  chmod 600 /home/claude/.atlassian-creds
  chown claude:claude /home/claude/.atlassian-creds
fi

# Generate minimal .claude.json to skip onboarding wizard
# Claude Code requires this file with hasCompletedOnboarding to skip first-run setup
echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > /home/claude/.claude/.claude.json
ln -sf /home/claude/.claude/.claude.json /home/claude/.claude.json
chown claude:claude /home/claude/.claude/.claude.json /home/claude/.claude.json

# Pre-populate GitHub host key so /plugin and git clones work without strict-checking failures
mkdir -p /home/claude/.ssh
chmod 700 /home/claude/.ssh
ssh-keyscan -t ed25519,rsa,ecdsa github.com >> /home/claude/.ssh/known_hosts 2>/dev/null || true
chmod 600 /home/claude/.ssh/known_hosts
chown claude:claude /home/claude/.ssh /home/claude/.ssh/known_hosts

# Set up SSH config based on method passed via environment
SSH_METHOD="${SSH_METHOD:-none}"
case "$SSH_METHOD" in
  key-file)
    echo "Configuring SSH ($SSH_METHOD)..."
    # Copy the read-only mounted key so we can set ownership and permissions
    cp /home/claude/.ssh/user_key /home/claude/.ssh/id_key
    chmod 600 /home/claude/.ssh/id_key
    cat > /home/claude/.ssh/config <<'SSHEOF'
Host *
    User git
    IdentityFile /home/claude/.ssh/id_key
    StrictHostKeyChecking accept-new
SSHEOF
    chmod 600 /home/claude/.ssh/config
    chown claude:claude /home/claude/.ssh/config /home/claude/.ssh/id_key
    ;;
  agent)
    echo "Configuring SSH ($SSH_METHOD)..."
    cat > /home/claude/.ssh/config <<'SSHEOF'
Host *
    User git
    StrictHostKeyChecking accept-new
SSHEOF
    chmod 600 /home/claude/.ssh/config
    chown claude:claude /home/claude/.ssh/config
    ;;
  none)
    cat > /home/claude/.ssh/config <<'SSHEOF'
Host *
    StrictHostKeyChecking accept-new
SSHEOF
    chmod 600 /home/claude/.ssh/config
    chown claude:claude /home/claude/.ssh/config
    ;;
esac

# Rewrite git@github.com: SSH URLs to HTTPS so public repos clone without SSH auth
# This is needed for /plugin which clones public marketplace repos via SSH URLs
gosu claude git config --global url."https://github.com/".insteadOf "git@github.com:"

# Fix SSH agent socket permissions — Docker mounts it as root:root,
# but claude user needs read/write access to connect to the agent.
if [ "$SSH_METHOD" = "agent" ] && [ -S "/run/ssh-agent.sock" ]; then
  chown root:claude /run/ssh-agent.sock
  chmod 660 /run/ssh-agent.sock
fi

# Signal that setup is complete
touch /tmp/.claude-ready

# Keep container alive — Claude runs via `docker exec`
echo "Container ready. Waiting for connections..."
exec sleep infinity

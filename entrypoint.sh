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

# Copy credentials extracted from host keychain (overwrites mounted version)
if [ -f /mnt/host-credentials.json ]; then
  cp /mnt/host-credentials.json /home/claude/.claude/.credentials.json
  chmod 600 /home/claude/.claude/.credentials.json
  chown claude:claude /home/claude/.claude/.credentials.json
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

# Signal that setup is complete
touch /tmp/.claude-ready

# Keep container alive — Claude runs via `docker exec`
echo "Container ready. Waiting for connections..."
exec sleep infinity

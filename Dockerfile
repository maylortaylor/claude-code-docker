FROM node:22-slim

# Install tools Claude Code needs + firewall deps + PDF generation
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  openssh-client \
  jq \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  gosu \
  procps \
  python3 \
  pandoc \
  weasyprint \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install gh CLI (separate layer — needs ca-certificates for HTTPS)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user — entrypoint chowns mounted files at runtime
RUN useradd -m -s /bin/bash claude && \
  mkdir -p /home/claude/.claude /workspace && \
  chown -R claude:claude /home/claude /workspace

# ccusage (usage tracker) still ships via npm
ENV DEVCONTAINER=true
RUN npm install -g ccusage

# Claude Code via native installer (npm package deprecated). Installs to
# /home/claude/.local/bin/claude and self-updates from claude.ai at runtime —
# both domains are allowlisted in init-firewall.sh.
# CACHEBUST forces a fresh download: `docker build --build-arg CACHEBUST=$(date +%s) ...`
ARG CACHEBUST=1
ENV PATH=/home/claude/.local/bin:$PATH
RUN su - claude -c "curl -fsSL https://claude.ai/install.sh | bash"

# Copy firewall + entrypoint scripts (root-owned, not writable by claude)
COPY init-firewall.sh /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

# Entrypoint runs as root: sets firewall, then drops to claude user
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

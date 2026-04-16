# Local AI Agent — Design Spec

**Date:** 2026-04-16
**Status:** Approved for implementation
**Branch:** `feature/local-ai-agent`

---

## Summary

Add an opt-in "local AI agent" feature to claude-code-docker that lets Claude Sonnet/Opus delegate work to a locally-running Gemma 3 27B model via Ollama. Claude acts as orchestrator and quality reviewer; the local model handles routine coding tasks, batch processing, and background work — for free, on-device.

---

## Goals

- Claude delegates to the local model for routine/repetitive tasks; handles complex work itself
- Feature is **off by default** — explicit opt-in per session
- Zero changes to existing container lifecycle, auth, firewall, or profiles
- Works with both `claude-psd` and `claude-personal` profiles

---

## Architecture

```
Mac Host
├── Ollama  (OLLAMA_HOST=0.0.0.0, port 11434)
│   └── gemma3:27b — Metal GPU acceleration (M2 Max, ~15-17GB)
│
└── ~/Documents/_dev/  ← mounted into Docker as-is

Docker Container (claude-code-docker, unchanged externally)
├── Claude Code (Sonnet/Opus) ← user chats here
│   └── calls MCP tools to delegate tasks
│
├── local-agent MCP Server  (Python, stdio, launched by Claude Code)
│   ├── checks ~/.local-agent-enabled flag on every call
│   ├── local_agent_task()    — tight loop: Aider or direct Ollama, blocks until done
│   ├── local_agent_queue()   — async: drops task spec to queue dir, returns task_id
│   ├── local_agent_status()  — check a queued task or list all pending/done
│   └── local_agent_toggle()  — enable/disable from within Claude (alternative to shell)
│
├── Aider  (installed in Docker image)
│   └── configured: --model ollama_chat/gemma3:27b
│   └── calls host.docker.internal:11434  (host gateway already allowed by firewall)
│
└── Queue Watcher  (bash background loop, starts with container via entrypoint.sh)
    ├── watches ~/.local-agent-queue/pending/
    ├── runs Aider or direct Ollama call per task file
    └── writes results to ~/.local-agent-queue/done/
```

### Firewall note

`init-firewall.sh` line 73-74 already adds the Docker host gateway IP to the allowlist for Docker networking. Since `host.docker.internal` resolves to this same IP, Ollama on the host is reachable from the container **with no firewall changes required**.

Ollama requires one configuration change on the host: `OLLAMA_HOST=0.0.0.0` so it binds to all interfaces (not just loopback). This is set via a LaunchAgent plist or `~/.zshrc`.

---

## Components

### 1. `local-agent-mcp.py` (new file, copied into Docker image)

Python MCP server, stdio transport. Exposes four tools to Claude Code.

**On/off gate:** Every tool call checks for `~/.local-agent-enabled`. If absent, returns:
> `"Local agent is disabled. Handle this task directly."`

**Tools:**

| Tool | Mode | Behaviour |
|------|------|-----------|
| `local_agent_task` | Synchronous | Invokes Aider (multi-file) or direct Ollama call (simple). Blocks until done, returns summary + file diff list. |
| `local_agent_queue` | Async | Writes a JSON task spec to `~/.local-agent-queue/pending/<uuid>.json`. Returns `task_id`. |
| `local_agent_status` | Read | With `task_id`: returns status + result. Without: lists all pending/done tasks. |
| `local_agent_toggle` | Control | Creates or removes `~/.local-agent-enabled`. Reports new state. |

**Task routing inside `local_agent_task`:**
- Multi-file or complex edits → Aider subprocess (`aider --model ollama_chat/gemma3:27b --yes ...`)
- Single-file or generation tasks → direct Ollama HTTP call (faster, no Aider overhead)
- Claude decides which to use via a `mode` parameter: `"aider"` | `"direct"` | `"auto"` (default)

### 2. `queue-watcher.sh` (new file, copied into Docker image)

Bash loop. Runs as a background process started by `entrypoint.sh`.

```
while true; do
  for task in ~/.local-agent-queue/pending/*.json; do
    process task → run Aider or direct Ollama
    write result to ~/.local-agent-queue/done/<id>.json
    remove from pending/
  done
  sleep 5
done
```

Only runs tasks when `~/.local-agent-enabled` exists. Sleeps and polls when disabled.

### 3. `Dockerfile` (two additions)

```dockerfile
# Install Aider and MCP + HTTP dependencies
RUN pip3 install aider-chat httpx mcp

# Copy local agent scripts
COPY local-agent-mcp.py /usr/local/lib/local-agent-mcp.py
COPY queue-watcher.sh /usr/local/bin/queue-watcher.sh
RUN chmod +x /usr/local/bin/queue-watcher.sh
```

### 4. `entrypoint.sh` (one addition)

Start the queue watcher as a background process after setup:

```bash
# Start local agent queue watcher (runs as claude user, checks enabled flag itself)
su - claude -c "queue-watcher.sh &"
```

### 5. `settings.json` (MCP server registration)

Add to each profile's `settings.json` (`~/.claude-psd/settings.json`, `~/.claude-personal/settings.json`):

```json
{
  "mcpServers": {
    "local-agent": {
      "command": "python3",
      "args": ["/usr/local/lib/local-agent-mcp.py"]
    }
  }
}
```

### 6. Shell function updates (`~/.zshrc-claude-psd`, `~/.zshrc-claude-personal`)

Add `--agent-on` / `--agent-off` flag parsing before forwarding args to `run-claude.sh`:

```bash
# Parse --agent-on / --agent-off before passing remaining args to run-claude.sh
_claude_run() {
  local agent_flag="" remaining=()
  for arg in "$@"; do
    case "$arg" in
      --agent-on)  agent_flag="on" ;;
      --agent-off) agent_flag="off" ;;
      *)           remaining+=("$arg") ;;
    esac
  done
  if   [ "$agent_flag" = "on"  ]; then touch ~/.local-agent-enabled && echo "Local agent: ON"
  elif [ "$agent_flag" = "off" ]; then rm -f ~/.local-agent-enabled  && echo "Local agent: OFF"
  fi
  run-claude.sh "${remaining[@]}"
}
```

Aliases become (using actual paths from the existing zshrc functions):
```bash
alias claude-psd="_claude_run --conf <path-to>/claude-docker-psd.conf"
alias claude-personal="_claude_run --conf <path-to>/claude-docker-personal.conf"
```
Implementation reads the existing `~/.zshrc-claude-psd` and `~/.zshrc-claude-personal` to determine the current alias structure before modifying.

---

## On/Off Behaviour

| Command | Effect |
|---------|--------|
| `claude-psd` | Starts normally; agent state = whatever flag file currently is |
| `claude-psd --agent-on` | Creates flag file, then starts |
| `claude-psd --agent-off` | Removes flag file, then starts |
| `agent-on` (optional alias) | Creates flag file mid-session |
| `agent-off` (optional alias) | Removes flag file mid-session |

**Default:** OFF. Flag file does not exist until explicitly created.
**Persistence:** Flag file survives container restarts. Set it once per "agent day", clear it when done.
**Both profiles share the flag file** — one toggle controls both.

---

## Data Flows

### Tight Loop (synchronous delegation)

```
User asks Claude to implement feature X
  → Claude decomposes into a focused task
  → Claude calls local_agent_task(description, files, mode="auto")
  → MCP server checks ~/.local-agent-enabled  ✓
  → MCP server invokes Aider subprocess
  → Aider calls host.docker.internal:11434 (Ollama / Gemma)
  → Gemma reasons, generates edits
  → Aider applies edits to mounted filesystem
  → MCP server returns summary + changed files to Claude
  → Claude reviews, iterates or accepts
```

### Background Queue (async)

```
Claude calls local_agent_queue(description, files, priority)
  → MCP writes ~/.local-agent-queue/pending/<uuid>.json
  → Returns task_id to Claude immediately
  → Claude continues with other work
  → Queue watcher picks up task (within 5s)
  → Runs Aider, writes ~/.local-agent-queue/done/<uuid>.json
  → User or Claude calls local_agent_status(task_id) to retrieve result
```

---

## UX Differences: Claude vs Local Agent

| Aspect | Claude Code (Sonnet/Opus) | Local Agent (Gemma) |
|--------|--------------------------|---------------------|
| Edits appear as | Inline diffs in chat UI, approve/deny per file | Silent — changes on disk, summary returned to Claude |
| Permission prompt | Yes | No |
| Visibility | Claude Code UI | `git diff` |
| Quality | High, self-corrects | Good for focused tasks; Claude reviews output |
| Cost | API tokens | Free (on-device) |

Claude always supervises local agent output. For anything critical or ambiguous, Claude handles it directly rather than delegating.

---

## What Does NOT Change

- `run-claude.sh` — untouched
- `init-firewall.sh` — untouched (host gateway already allowed)
- Container lifecycle, auth, SSH, credential forwarding — untouched
- Multi-profile setup — both profiles get the feature automatically
- `claude-docker-psd.conf` / `claude-docker-personal.conf` — untouched

---

## Host Setup (one-time, outside Docker)

```bash
# 1. Install Ollama
brew install ollama

# 2. Pull Gemma 3 27B
ollama pull gemma3:27b

# 3. Configure Ollama to listen on all interfaces (so Docker can reach it)
# Add to ~/.zshrc or configure via LaunchAgent:
export OLLAMA_HOST=0.0.0.0

# 4. Start Ollama (or set up as a LaunchAgent for auto-start)
ollama serve
```

---

## Files Changed / Created

| File | Change |
|------|--------|
| `local-agent-mcp.py` | **New** — MCP server |
| `queue-watcher.sh` | **New** — background task runner |
| `Dockerfile` | **Modified** — add pip packages, copy scripts |
| `entrypoint.sh` | **Modified** — start queue watcher |
| `settings.json.example` | **Modified** — add mcpServers example |
| `README.md` | **Modified** — document local agent feature |
| `~/.zshrc-claude-psd` | **Modified** — add --agent-on/off flag parsing |
| `~/.zshrc-claude-personal` | **Modified** — same |

---

## Out of Scope

- Automatic model selection / routing logic beyond `"auto"` | `"aider"` | `"direct"`
- Web UI or dashboard for queue status
- Multiple simultaneous local model workers
- Support for models other than `gemma3:27b` at launch (configurable later via env var)
- NeMo, LM Studio, or other inference runtimes (Ollama only)

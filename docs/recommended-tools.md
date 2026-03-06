# Recommended Tools

Clawdboss includes integration guides for vetted OpenClaw ecosystem tools. All are optional — the setup wizard will prompt you for each one.

---

## MCP Servers

### OCTAVE Protocol — Token Compression

**What:** Structured document format for LLM communication. 3-20x token compression with schema validation and deterministic artifacts for multi-agent handoffs.

**Install:** Prompted during setup, or manually:
```bash
uv venv ~/.octave-venv && uv pip install octave-mcp
# OR: python3 -m venv ~/.octave-venv && ~/.octave-venv/bin/pip install octave-mcp
```

**Register:**
```bash
mcporter config add octave --command ~/.octave-venv/bin/octave-mcp-server --transport stdio
```

---

### Graphthulhu — Knowledge Graph Memory

**What:** Typed knowledge graph for structured agent memory. Define entities (Person, Project, Task, Event), relationships, and constraints. Shared knowledge base across all agents.

**Install:** Prompted during setup, or manually:
```bash
# Via cargo (if Rust installed)
cargo install graphthulhu

# OR download pre-built binary from GitHub releases
curl -fsSL -o ~/.local/bin/graphthulhu \
  https://github.com/scottozolmedia/graphthulhu/releases/latest/download/graphthulhu-linux-x86_64
chmod +x ~/.local/bin/graphthulhu
```

**Register:**
```bash
# Create an Obsidian vault directory
mkdir -p ~/.openclaw/vault
mcporter config add graphthulhu --command "graphthulhu serve --backend obsidian --vault ~/.openclaw/vault"
```

**Links:**
- GitHub: <https://github.com/scottozolmedia/graphthulhu>

---

### ApiTap — API Discovery

**What:** Intercepts web API traffic during browsing and generates portable skill files so agents can call APIs directly instead of scraping. Headless API discovery — agents learn how APIs work by watching you use them.

**Install:** Prompted during setup, or manually:
```bash
npm install -g @apitap/core
```

**Register:**
```bash
mcporter config add apitap --command apitap-mcp --transport stdio
```

**Links:**
- npm: `@apitap/core`

---

## Python Tools

### Scrapling — Anti-Bot Web Scraping

**What:** High-performance Python web scraping with anti-bot bypass. Adaptive selectors that survive site redesigns. Structured data extraction from JS-rendered and anti-bot-protected pages.

**Install:** Prompted during setup, or manually:
```bash
pip install scrapling
```

**Usage:** Agents use it as a Python library through the `scrapling` OpenClaw skill. No MCP registration needed — the skill handles everything.

**Links:**
- GitHub: <https://github.com/D4Vinci/Scrapling>
- PyPI: `scrapling`

---

## Skills

### GitHub — Issues, PRs, CI/CD

**What:** Full GitHub integration via the `gh` CLI. Create issues, review PRs, search code, check CI runs, and automate DevOps workflows.

**Install:** Prompted during setup, or manually:
```bash
# Install gh CLI (https://cli.github.com)
# Then install the skill:
npx clawhub@latest install github
```

**Authenticate:**
```bash
gh auth login
```

---

### Playwright MCP — Browser Automation

**What:** Navigate websites, click elements, fill forms, take screenshots. Full browser automation for complex web workflows that go beyond simple scraping.

**Install:** Prompted during setup, or manually:
```bash
npx clawhub@latest install playwright-mcp
```

---

## Observability & Security

### Clawmetry — Observability Dashboard

**What:** Real-time monitoring dashboard showing token costs, sessions, cron jobs, sub-agents, memory, and live message flow. Zero config — auto-detects everything.

**Install:**
```bash
pip install clawmetry
clawmetry
# Opens at http://localhost:8900
```

**What you get:**
- **Flow** — Live animated diagram of messages through channels → brain → tools → response
- **Usage** — Token and cost tracking with daily/weekly/monthly breakdowns
- **Sessions** — Active agent sessions with model, tokens, last activity
- **Crons** — Scheduled jobs with status, next run, duration
- **Logs** — Color-coded real-time log streaming
- **Memory** — Browse SOUL.md, MEMORY.md, AGENTS.md, daily notes
- **Transcripts** — Chat-bubble UI for reading session histories

**Configuration (optional):**
```bash
clawmetry --port 9000           # Custom port (default: 8900)
clawmetry --host 127.0.0.1      # Bind to localhost only
clawmetry --workspace ~/mybot   # Custom workspace path
```

**Links:**
- GitHub: <https://github.com/vivekchand/clawmetry>
- Website: <https://clawmetry.com>
- License: MIT (free, open-source)

---

## ClawSec — Security Suite

**What:** Complete security skill suite from [Prompt Security](https://prompt.security). Provides drift detection for agent files (SOUL.md, AGENTS.md), advisory feed monitoring, and malicious skill detection.

**Install:**
```bash
# Option A: Via clawhub
npx clawhub@latest install clawsec-suite

# Option B: Manual from GitHub
git clone --depth 1 https://github.com/prompt-security/clawsec.git /tmp/clawsec
cp -r /tmp/clawsec/skills/clawsec-suite ~/.openclaw/skills/
cp -r /tmp/clawsec/skills/soul-guardian ~/.openclaw/skills/
cp -r /tmp/clawsec/skills/clawsec-feed ~/.openclaw/skills/
rm -rf /tmp/clawsec
```

### Soul Guardian — File Integrity Protection

Detects unauthorized changes to SOUL.md, AGENTS.md, IDENTITY.md and auto-restores critical files.

```bash
# Initialize baselines (run once after setup)
cd ~/.openclaw/workspace
python3 ~/.openclaw/skills/soul-guardian/scripts/soul_guardian.py init --actor setup --note "initial baseline"

# Test the check
python3 ~/.openclaw/skills/soul-guardian/scripts/soul_guardian.py check --actor test --output-format alert
```

### Advisory Feed — Vulnerability Monitoring

Polls the ClawSec advisory feed for CVEs and malicious skill reports. Cross-references against your installed skills.

Add to your `HEARTBEAT.md` for automatic monitoring:
```markdown
## Soul Guardian Check
- Run `python3 ~/.openclaw/skills/soul-guardian/scripts/soul_guardian.py check --actor heartbeat --output-format alert`
- If any output is produced, relay it as a security alert

## ClawSec Advisory Feed (weekly)
- Check ~/.openclaw/clawsec-suite-feed-state.json for last check time
- Run advisory feed check from ~/.openclaw/skills/clawsec-suite/HEARTBEAT.md
- Report any new advisories affecting installed skills
```

**Links:**
- GitHub: <https://github.com/prompt-security/clawsec>
- Website: <https://clawsec.prompt.security>
- License: MIT (free, open-source)
- Requires: python3, curl (jq optional)

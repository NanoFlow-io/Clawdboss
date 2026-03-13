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
  https://github.com/skridlevsky/graphthulhu/releases/latest/download/graphthulhu-linux-x86_64
chmod +x ~/.local/bin/graphthulhu
```

**Register:**
```bash
# Create an Obsidian vault directory
mkdir -p ~/.openclaw/vault
mcporter config add graphthulhu --command "graphthulhu serve --backend obsidian --vault ~/.openclaw/vault"
```

**Links:**
- GitHub: <https://github.com/skridlevsky/graphthulhu>

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

### Humanizer — AI Writing De-AIification

**What:** Detects and removes signs of AI-generated writing. Scans for 24 AI writing patterns using 500+ vocabulary terms, statistical text analysis (burstiness, perplexity), and applies safe auto-replacements to make text sound natural and human.

**Install:** Prompted during setup, or manually:
```bash
npx clawhub@latest install humanizer
# OR from GitHub:
git clone --depth 1 https://github.com/brandonwise/humanizer.git ~/.openclaw/workspace/skills/humanizer
```

**Usage:** Agents automatically use the skill when writing content. Can also be run as a standalone CLI tool.

**Links:**
- GitHub: <https://github.com/brandonwise/humanizer>
- ClawHub: `humanizer`

---

### Self-Improving Agent — Continuous Learning

**What:** Captures errors, corrections, and lessons learned to enable continuous improvement. Automatically triggers when commands fail, users correct the agent, a better approach is discovered, or external APIs break. Reviews past learnings before major tasks.

**Install:** Prompted during setup, or manually:
```bash
npx clawhub@latest install self-improving-agent
```

**How it works:**
- Agent detects failures, corrections ("Actually...", "No, that's wrong..."), and outdated knowledge
- Logs learnings to a structured file that persists across sessions
- Reviews relevant learnings before starting new tasks to avoid repeating mistakes

**Links:**
- ClawHub: `self-improving-agent`

---

### Find Skills — Skill Discovery Helper

**What:** Helps agents discover and install new skills on-the-fly from ClawHub. When you ask "how do I do X?" or "is there a skill for Y?", the agent searches the ClawHub marketplace for matching skills and can install them immediately.

**Install:** Prompted during setup, or manually:
```bash
npx clawhub@latest install find-skills
```

**Links:**
- ClawHub: `find-skills`
- Marketplace: <https://clawhub.com>

---

### Marketing Skills — Marketing Reference Library

**What:** 15+ marketing reference skills covering copywriting, CRO (conversion rate optimization), SEO audits, email sequences, A/B testing, pricing strategy, paid ads, social content, launch strategy, and more. Each skill provides structured frameworks and best practices the agent follows when working on marketing tasks.

**Install:** Prompted during setup, or manually:
```bash
npx clawhub@latest install marketing-skills
```

**Included skills:**
- Copywriting, Copy Editing
- Page CRO, Signup Flow CRO, Form CRO, Popup CRO, Onboarding CRO, Paywall/Upgrade CRO
- SEO Audit, Programmatic SEO, Schema Markup
- Email Sequences, Social Content
- A/B Test Setup, Analytics Tracking
- Pricing Strategy, Launch Strategy
- Paid Ads, Referral Programs
- Marketing Ideas, Marketing Psychology
- Competitor/Alternatives Pages, Free Tool Strategy

**Links:**
- ClawHub: `marketing-skills`

---

### Healthcheck — Host Security Hardening

**What:** Built-in OpenClaw skill that audits host security: firewall configuration, SSH hardening, system updates, network exposure, and risk posture. Can be scheduled via heartbeat or cron for periodic security scans.

**Install:** Built-in with OpenClaw (no separate install needed). Prompted during setup to verify availability.

**Usage:**
```
"Run a healthcheck on this machine"
"Check if SSH is hardened"
"Audit my firewall configuration"
```

**Links:**
- Built-in with OpenClaw

---

### fail2ban — Brute-Force Protection

**What:** Intrusion prevention framework that monitors log files (SSH, web servers, etc.) and automatically bans IPs showing malicious signs — too many password failures, exploit-seeking requests, etc. Essential for any internet-facing server.

**Install:** Prompted during setup, or manually:
```bash
# Debian/Ubuntu
sudo apt-get install fail2ban

# Fedora/RHEL
sudo dnf install fail2ban

# Arch
sudo pacman -S fail2ban

# Enable and start
sudo systemctl enable --now fail2ban
```

**Default jail config** (created by setup wizard at `/etc/fail2ban/jail.local`):
```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
```

**Useful commands:**
```bash
sudo fail2ban-client status          # List active jails
sudo fail2ban-client status sshd     # SSH jail details
sudo fail2ban-client set sshd unbanip <IP>  # Unban an IP
```

**Links:**
- GitHub: <https://github.com/fail2ban/fail2ban>

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

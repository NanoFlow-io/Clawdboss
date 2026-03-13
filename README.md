# 🦞 Clawdboss

**Pre-hardened, multi-agent OpenClaw setup by NanoFlow.**

One script to go from zero to a fully secured, multi-agent AI assistant on Discord — with prompt injection defense, security auditing, WAL Protocol for context persistence, and best practices baked in.

## What You Get

- **Multi-agent architecture** — Main agent + optional specialist agents (Comms, Research, Security)
- **Security-first** — Prompt injection defense, anti-loop rules, content tagging, credential isolation
- **WAL Protocol** — Write-Ahead Log for corrections, decisions, and details that survive context loss
- **Working Buffer** — Danger zone logging to survive context compaction without losing work
- **Discord integration** — Bot bound to your server with channel-per-agent routing
- **Telegram integration** — Chat via Telegram bot with DM and group support
- **Web dashboard** — ClawSuite Console with chat, file browser, terminal, cost analytics (optional)
- **Env-based secrets** — All API keys in `.env`, never in config files
- **Automated security audits** — Security agent runs scheduled hardening checks
- **Knowledge graph** — Graphthulhu for structured memory across agents (optional)
- **API discovery** — ApiTap intercepts web traffic to teach agents how APIs work (optional)
- **Web scraping** — Scrapling for anti-bot-bypassing data extraction (optional)
- **Browser automation** — Playwright MCP for full GUI workflows (optional)
- **GitHub integration** — Issues, PRs, CI/CD via `gh` CLI (optional)
- **Token compression** — OCTAVE protocol for 3-20x compression in multi-agent handoffs (optional)
- **Observability** — Clawmetry dashboard for token costs, sessions, live message flow (optional)
- **Security suite** — ClawSec for file integrity, advisory feed, malicious skill detection (optional)
- **AI text humanizer** — Humanizer detects and removes AI writing patterns (optional)
- **Continuous learning** — Self-Improving Agent captures errors and lessons across sessions (optional)
- **Skill discovery** — Find Skills helps agents install new capabilities on-the-fly (optional)
- **Marketing toolkit** — 15+ marketing reference skills for copywriting, CRO, SEO, and more (optional)
- **Host hardening** — Healthcheck audits firewall, SSH, updates, and exposure (optional)

## Quick Start

### Ubuntu VPS (Fresh Install)

SSH into your server and run:

```bash
# 1. Clone Clawdboss
apt-get update && apt-get install -y git
git clone https://github.com/NanoFlow-io/clawdboss.git
cd clawdboss

# 2. Run the setup wizard (auto-installs Node.js 22, Python, build tools, OpenClaw)
./setup.sh
```

That's it. The wizard auto-installs all dependencies (Node.js 22, Python, git, build-essential, OpenClaw) and walks you through everything else.

### What You'll Need Ready

- **An LLM provider** — one of:
  - [GitHub Copilot](https://github.com/features/copilot) subscription (cheapest — uses copilot-api proxy)
  - [OpenAI API key](https://platform.openai.com/api-keys) (sk-...)
  - [Anthropic API key](https://console.anthropic.com/) (sk-ant-...)
- **A Discord bot token** — [create one here](https://discord.com/developers/applications) (if using Discord interface)
- **A Telegram bot token** — [create one via @BotFather](https://t.me/BotFather) (if using Telegram interface)
- **Optional:** Brave Search API key, ElevenLabs API key, OpenAI key for image gen/whisper

The setup wizard will:
1. Ask about **you** — name, role, what you do, how you want to use your agent
2. Ask about **your agent** — name, personality, mission, domain expertise
3. Prompt for your API keys and Discord/Telegram credentials
4. Create your `.env` file (gitignored, never committed)
5. Generate `openclaw.json` with `${VAR}` references to your `.env`
6. Create agent workspaces with security rules + WAL Protocol pre-baked
7. Offer optional tools: Graphthulhu, ApiTap, Scrapling, GitHub, Playwright, OCTAVE, Humanizer, Self-Improving Agent, Find Skills, Marketing Skills, Healthcheck, Clawmetry, ClawSec
8. Run OpenClaw's built-in skills wizard (Whisper, Nano Banana Pro, mcporter, TTS, email, etc.)
9. Start the gateway

Your agent starts its first session knowing who you are, what you do, and what personality it should have — zero manual config file editing needed.

## Configuration Tiers

| Tier | Agents | Best For |
|------|--------|----------|
| **Solo** | Main only | Personal assistant, simple setups |
| **Team** | Main + 1-2 specialists | Small business, multiple workflows |
| **Full Squad** | Main + Comms + Research + Security | Full operations center |

## File Structure

```
clawdboss/
├── README.md
├── setup.sh                    # Interactive setup wizard
├── .env.example                # Template showing required variables
├── .gitignore                  # Protects secrets
├── templates/
│   ├── openclaw.template.json  # Config with ${VAR} placeholders
│   ├── workspace/              # Main agent workspace files
│   │   ├── AGENTS.md           # Operating rules + WAL Protocol + security
│   │   ├── SOUL.md
│   │   ├── USER.md
│   │   ├── TOOLS.md
│   │   ├── IDENTITY.md
│   │   └── HEARTBEAT.md
│   └── agents/                 # Specialist agent templates
│       ├── comms/
│       ├── research/
│       └── security/
└── docs/
    ├── security.md             # Security architecture + WAL Protocol overview
    ├── customization.md        # How to customize your setup
    ├── recommended-tools.md    # Vetted ecosystem tools (Clawmetry, ClawSec)
    └── octave.md               # OCTAVE protocol guide
```

## Interface Options

During setup, choose your preferred interface:

| Option | Best For |
|--------|----------|
| **Discord** | Power users who live in Discord. Channel-per-agent, reactions, threads. |
| **Telegram** | Mobile-first. DM your bot or use group topics for multi-agent routing. |
| **ClawSuite Console** | Visual dashboard with chat, file browser, terminal, cost analytics. Great for non-technical users. |
| **Any combination** | Mix and match — Discord + Telegram, Discord + Console, all three, etc. |

ClawSuite Console is an open-source web dashboard — see [ClawSuite on GitHub](https://github.com/outsourc-e/clawsuite) (MIT license).

## Context Persistence (WAL Protocol + 3-Layer Memory)

Clawdboss agents don't lose your corrections and decisions when context resets:

- **3-Layer Memory** — L1 (Brain, loaded every turn) → L2 (Memory, searched semantically) → L3 (Reference, opened on demand)
- **L1 File Budget** — 500-1,000 tokens per workspace file to prevent agents from skimming
- **SESSION-STATE.md** — Agent writes important details here BEFORE responding (Write-Ahead Log)
- **Working Buffer** — At ~60% context, every exchange is logged to survive compaction
- **Compaction Recovery** — Agent reads buffer + state files after context loss, never asks "what were we doing?"
- **Breadcrumbs** — Topic-organized files in `memory/` that point to deep reference docs
- **Trim** — Weekly maintenance to keep L1 files lean, move excess to L2/L3
- **Recalibrate** — Drift correction, forces re-read of all files and behavior comparison

See [docs/security.md](docs/security.md) for the full architecture.

## Security

All API keys are stored in `~/.openclaw/.env` and referenced via `${VAR_NAME}` syntax in the config. Keys never appear in JSON config files.

All agents come with:
- Prompt injection defense (content isolation, pattern detection)
- Anti-loop rules (prevent token-burning attacks)
- External content security (emails, web pages treated as data-only)
- Relentless resourcefulness + VBR (Verify Before Reporting)

See [docs/security.md](docs/security.md) for the full security architecture.

## Recommended Ecosystem Tools

The setup wizard offers each of these individually. All are free and open-source:

| Tool | Purpose | Install Method |
|------|---------|---------------|
| **[Graphthulhu](https://github.com/skridlevsky/graphthulhu)** | Knowledge graph memory (entities, relationships, constraints) | Binary / cargo |
| **[ApiTap](https://www.npmjs.com/package/@apitap/core)** | API discovery — intercepts web traffic, generates skill files | `npm install -g @apitap/core` |
| **[Scrapling](https://github.com/D4Vinci/Scrapling)** | Anti-bot web scraping with adaptive selectors | `pip install scrapling` |
| **[Playwright MCP](https://clawhub.com/playwright-mcp)** | Full browser automation (navigate, click, fill, screenshot) | `clawhub install` |
| **[GitHub](https://cli.github.com)** | Issues, PRs, CI/CD via `gh` CLI | `clawhub install` + `gh` CLI |
| **[OCTAVE](https://pypi.org/project/octave-mcp/)** | 3-20x token compression for multi-agent handoffs | `pip install octave-mcp` |
| **[Clawmetry](https://clawmetry.com)** | Real-time observability dashboard (costs, sessions, flow) | `pip install clawmetry` |
| **[ClawSec](https://github.com/prompt-security/clawsec)** | File integrity, advisory feed, malicious skill detection | Git clone |
| **[Humanizer](https://github.com/brandonwise/humanizer)** | Detect and remove AI writing patterns (24 patterns, 500+ terms) | `clawhub install` |
| **Self-Improving Agent** | Capture errors, corrections, and lessons for continuous learning | `clawhub install` |
| **Find Skills** | Discover and install new skills on-the-fly from ClawHub | `clawhub install` |
| **Marketing Skills** | 15+ marketing reference skills (copywriting, CRO, SEO, email, ads) | `clawhub install` |
| **Healthcheck** | Host security audits: firewall, SSH, updates, exposure | Built-in |
| **[fail2ban](https://github.com/fail2ban/fail2ban)** | Brute-force protection — auto-bans malicious IPs | `apt install fail2ban` |

See [docs/recommended-tools.md](docs/recommended-tools.md) for detailed install guides.

## After Install — Getting Your Agent Running

Once the wizard finishes, follow the next steps it shows:

### 1. Start the LLM Provider

**GitHub Copilot (proxy):**
```bash
# First run — shows a device auth URL + code. Open the URL, enter the code,
# authorize with a GitHub account that has an active Copilot subscription ($10/mo).
npx copilot-api start --port 4141

# Run in background (recommended):
tmux new-session -d -s copilot 'npx copilot-api start --port 4141'
```

**OpenAI / Anthropic:** No proxy needed — your API key is already in `.env`.

### 2. Start OpenClaw

```bash
openclaw gateway start
openclaw status       # Verify everything is running
```

### 3. Start ClawSuite Console (if selected)

```bash
cd ~/clawsuite && HOST=0.0.0.0 PORT=3000 node server-entry.js

# Run in background:
tmux new-session -d -s console 'cd ~/clawsuite && HOST=0.0.0.0 PORT=3000 node server-entry.js'
```

Then open in your browser:
- **Local:** `http://localhost:3000`
- **Remote/VPS:** `http://YOUR-SERVER-IP:3000`

### 4. Chat with Your Agent

- **Discord:** Open the channel you configured and send a message
- **ClawSuite Console:** Use the chat panel in the web dashboard
- **Both:** Use either — they connect to the same agent

## Memory System (Hybrid Plugin)

Clawdboss includes a custom **memory-hybrid plugin** that gives your agent two-tier persistent memory:

- **SQLite + FTS5** — Structured facts with full-text search. Instant, zero API cost. Stores entities, preferences, decisions with auto-expiry and confidence decay.
- **LanceDB** — Semantic vector search for fuzzy/contextual recall. Uses OpenAI embeddings (`text-embedding-3-small`).

Both backends are queried in parallel, results merged and deduplicated. The agent gets `memory_store`, `memory_recall`, `memory_forget`, `memory_checkpoint`, and `memory_prune` tools automatically.

**Requires:** An OpenAI API key for embeddings (set `EMBEDDING_API_KEY` in your `.env`).

**CLI commands:**
```bash
openclaw hybrid-mem stats           # Show memory statistics
openclaw hybrid-mem search "query"  # Search across both backends
openclaw hybrid-mem prune           # Remove expired memories
```

## Requirements

- Ubuntu 22.04+ (or any Linux with bash)
- Node.js 22+ (setup wizard installs OpenClaw automatically)
- 2GB+ RAM recommended (1GB works for Solo tier)
- A Discord bot token ([create one here](https://discord.com/developers/applications)) and/or Telegram bot token (from [@BotFather](https://t.me/BotFather))
- An LLM provider (GitHub Copilot, OpenAI, Anthropic, or others)
- Optional: Brave Search API key, ElevenLabs API key

## License

MIT — see [LICENSE](LICENSE) for details.

#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Clawdboss Setup Wizard
# Pre-hardened, multi-agent OpenClaw setup by NanoFlow
# ============================================================

# Security: restrict file creation to owner-only by default
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
OPENCLAW_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
ENV_FILE="$OPENCLAW_DIR/.env"
CONFIG_FILE="$OPENCLAW_DIR/openclaw.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}  ${BOLD}🦞 Clawdboss Setup Wizard${NC}                   ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  Pre-hardened OpenClaw by NanoFlow            ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
}

info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✅${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠️${NC}  $1"; }
error()   { echo -e "${RED}❌${NC} $1"; }
ask()     { echo -en "${CYAN}?${NC}  $1: "; }

# Generate a random token (use absolute paths to prevent PATH hijacking)
random_token() {
  /usr/bin/openssl rand -hex 32 2>/dev/null \
    || /usr/bin/python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
    || openssl rand -hex 32 2>/dev/null \
    || python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
    || head -c 64 /dev/urandom | xxd -p -c 64
}

# ============================================================
# Input validation
# ============================================================

# Validate names: alphanumeric, hyphens, underscores, spaces only
validate_name() {
  local name="$1"
  local label="${2:-Name}"
  if [[ ! "$name" =~ ^[a-zA-Z0-9\ _-]+$ ]]; then
    error "Invalid $label: must contain only letters, numbers, spaces, hyphens, and underscores"
    return 1
  fi
  echo "$name"
}

# Validate agent ID: alphanumeric, hyphens, underscores only (no spaces, no path chars)
validate_agent_id() {
  local id="$1"
  if [[ ! "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "Invalid agent ID: must contain only letters, numbers, hyphens, and underscores"
    return 1
  fi
  # Reject path traversal patterns
  if [[ "$id" == *".."* || "$id" == *"/"* ]]; then
    error "Invalid agent ID: path traversal detected"
    return 1
  fi
  echo "$id"
}

# Validate Discord snowflake IDs: 17-19 digit numbers
validate_snowflake() {
  local id="$1"
  local label="${2:-ID}"
  if [[ ! "$id" =~ ^[0-9]{17,20}$ ]]; then
    error "Invalid Discord $label: must be a 17-20 digit number"
    return 1
  fi
  echo "$id"
}

# Validate timezone format
validate_timezone() {
  local tz="$1"
  if [[ ! "$tz" =~ ^[a-zA-Z_]+/[a-zA-Z_]+(/[a-zA-Z_]+)?$ ]] && [[ "$tz" != "UTC" ]]; then
    warn "Timezone '$tz' doesn't match expected format (e.g., America/Los_Angeles). Using anyway."
  fi
  echo "$tz"
}

# Validate path is under expected parent (prevent path traversal)
validate_path_under() {
  local path="$1"
  local parent="$2"
  local resolved
  resolved=$(realpath -m "$path" 2>/dev/null || echo "$path")
  if [[ "$resolved" != "$parent"* ]]; then
    error "Path traversal detected: $path resolves outside $parent"
    return 1
  fi
  echo "$resolved"
}

# Check for symlink attacks before writing
safe_write_check() {
  local filepath="$1"
  if [[ -L "$filepath" ]]; then
    error "SECURITY: $filepath is a symbolic link. Aborting to prevent symlink attack."
    exit 1
  fi
}

# ============================================================
# Pre-flight checks
# ============================================================

preflight() {
  info "Running pre-flight checks..."

  # Auto-install Node.js 22 if not found or version too old
  local need_node=false
  if ! command -v node &>/dev/null; then
    need_node=true
  else
    NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_VERSION" -lt 22 ]; then
      warn "Node.js 22+ required (found v$(node -v))"
      need_node=true
    fi
  fi

  if [ "$need_node" = true ]; then
    info "Installing Node.js 22..."
    if command -v curl &>/dev/null; then
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null \
        && apt-get install -y nodejs 2>/dev/null \
        && success "Node.js $(node -v) installed" \
        || {
          error "Could not auto-install Node.js. Install manually:"
          echo "  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
          echo "  sudo apt-get install -y nodejs"
          exit 1
        }
    else
      error "curl not found. Install Node.js 22 manually:"
      echo "  apt-get install -y curl"
      echo "  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
      echo "  sudo apt-get install -y nodejs"
      exit 1
    fi
  else
    success "Node.js $(node -v)"
  fi

  # Auto-install essential build tools
  local missing_pkgs=""
  command -v git &>/dev/null || missing_pkgs="$missing_pkgs git"
  command -v python3 &>/dev/null || missing_pkgs="$missing_pkgs python3"
  command -v make &>/dev/null || missing_pkgs="$missing_pkgs build-essential"
  command -v pip3 &>/dev/null || missing_pkgs="$missing_pkgs python3-pip"
  python3 -c "import ensurepip" &>/dev/null 2>&1 || missing_pkgs="$missing_pkgs python3-venv"

  if [ -n "$missing_pkgs" ]; then
    info "Installing dependencies:$missing_pkgs"
    apt-get update -qq 2>/dev/null
    apt-get install -y $missing_pkgs 2>/dev/null \
      && success "Dependencies installed" \
      || warn "Could not auto-install some packages. Install manually: sudo apt-get install -y$missing_pkgs"
  fi

  if ! command -v openclaw &>/dev/null; then
    warn "OpenClaw not found. Installing..."
    npm install -g openclaw@latest
  fi
  success "OpenClaw $(openclaw --version 2>/dev/null | head -1)"

  mkdir -p "$OPENCLAW_DIR"

  # Verify state dir is owned by current user
  if [[ "$(stat -c '%u' "$OPENCLAW_DIR" 2>/dev/null || stat -f '%u' "$OPENCLAW_DIR" 2>/dev/null)" != "$(id -u)" ]]; then
    error "$OPENCLAW_DIR is not owned by you. Possible security issue."
    exit 1
  fi

  success "State directory: $OPENCLAW_DIR"
  echo ""
}

# ============================================================
# Collect user info
# ============================================================

collect_user_info() {
  echo -e "${BOLD}--- About You ---${NC}"
  echo ""
  info "Let's get to know you so your agent can be genuinely useful from day one."
  echo ""

  while true; do
    ask "Your name"
    read -r USER_NAME
    USER_NAME="${USER_NAME:-User}"
    if validate_name "$USER_NAME" "name" >/dev/null 2>&1; then break; fi
  done

  ask "Your timezone (e.g., America/Los_Angeles, Europe/London)"
  read -r USER_TIMEZONE
  USER_TIMEZONE=$(validate_timezone "${USER_TIMEZONE:-UTC}")

  ask "Your location (city/region, e.g., 'Irvine, California' or 'London, UK')"
  read -r USER_LOCATION
  USER_LOCATION="${USER_LOCATION:-}"

  ask "Your pronouns (e.g., he/him, she/her, they/them)"
  read -r USER_PRONOUNS
  USER_PRONOUNS="${USER_PRONOUNS:-they/them}"

  echo ""
  echo -e "${BOLD}What do you do? (pick the closest)${NC}"
  echo ""
  echo "  1) Software developer / engineer"
  echo "  2) Founder / business owner"
  echo "  3) Marketer / growth"
  echo "  4) Creative (design, writing, music)"
  echo "  5) Operations / project management"
  echo "  6) Student / researcher"
  echo "  7) Other"
  echo ""
  ask "Your role [1-7]"
  read -r USER_ROLE_CHOICE
  USER_ROLE_CHOICE="${USER_ROLE_CHOICE:-7}"

  case "$USER_ROLE_CHOICE" in
    1) USER_ROLE="Software developer" ;;
    2) USER_ROLE="Founder / business owner" ;;
    3) USER_ROLE="Marketer / growth" ;;
    4) USER_ROLE="Creative (design, writing, music)" ;;
    5) USER_ROLE="Operations / project management" ;;
    6) USER_ROLE="Student / researcher" ;;
    *) USER_ROLE="Other" ;;
  esac

  echo ""
  ask "Brief description of what you do (e.g., 'I run a real estate company' or 'Full-stack dev at a startup')"
  read -r USER_DESCRIPTION
  USER_DESCRIPTION="${USER_DESCRIPTION:-}"

  echo ""
  echo -e "${BOLD}What will you primarily use your agent for?${NC}"
  echo ""
  echo "  1) Coding & development (write code, debug, review PRs)"
  echo "  2) Business operations (email, scheduling, research, CRM)"
  echo "  3) Marketing & content (copywriting, social media, SEO)"
  echo "  4) Research & analysis (web research, data analysis, reports)"
  echo "  5) Personal assistant (daily tasks, reminders, organization)"
  echo "  6) All of the above / general purpose"
  echo ""
  ask "Primary use case [1-6]"
  read -r USER_USECASE_CHOICE
  USER_USECASE_CHOICE="${USER_USECASE_CHOICE:-6}"

  case "$USER_USECASE_CHOICE" in
    1) USER_USECASE="Coding & development" ;;
    2) USER_USECASE="Business operations" ;;
    3) USER_USECASE="Marketing & content creation" ;;
    4) USER_USECASE="Research & analysis" ;;
    5) USER_USECASE="Personal assistant" ;;
    *) USER_USECASE="General purpose" ;;
  esac

  echo ""
  ask "Anything else your agent should know about you? (hobbies, communication style, pet peeves — or press Enter to skip)"
  read -r USER_EXTRA
  USER_EXTRA="${USER_EXTRA:-}"

  echo ""
}

# ============================================================
# Collect agent info
# ============================================================

collect_agent_info() {
  echo -e "${BOLD}--- Your Agent ---${NC}"
  echo ""
  info "Time to create your AI agent. Give it a name, personality, and purpose."
  echo ""

  while true; do
    ask "Agent name (letters, numbers, spaces, hyphens only)"
    read -r AGENT_NAME
    AGENT_NAME="${AGENT_NAME:-Assistant}"
    if validate_name "$AGENT_NAME" "agent name" >/dev/null 2>&1; then break; fi
  done

  ask "Agent pronouns (e.g., they/them, she/her, he/him)"
  read -r AGENT_PRONOUNS
  AGENT_PRONOUNS="${AGENT_PRONOUNS:-they/them}"

  echo ""
  echo -e "${BOLD}Pick an emoji for your agent:${NC}"
  echo ""
  echo "  1) 🤖  Robot        5) 🦊  Fox          9) 🎯  Bullseye"
  echo "  2) ⚡  Lightning    6) 🧠  Brain       10) 🔥  Fire"
  echo "  3) 🦾  Mech arm     7) 🎤  Microphone  11) 🌟  Star"
  echo "  4) 🚀  Rocket       8) 💡  Lightbulb   12) 🐙  Octopus"
  echo ""
  ask "Choose emoji [1-12, or type your own]"
  read -r EMOJI_CHOICE
  EMOJI_CHOICE="${EMOJI_CHOICE:-1}"

  case "$EMOJI_CHOICE" in
    1) AGENT_EMOJI="🤖" ;;
    2) AGENT_EMOJI="⚡" ;;
    3) AGENT_EMOJI="🦾" ;;
    4) AGENT_EMOJI="🚀" ;;
    5) AGENT_EMOJI="🦊" ;;
    6) AGENT_EMOJI="🧠" ;;
    7) AGENT_EMOJI="🎤" ;;
    8) AGENT_EMOJI="💡" ;;
    9) AGENT_EMOJI="🎯" ;;
    10) AGENT_EMOJI="🔥" ;;
    11) AGENT_EMOJI="🌟" ;;
    12) AGENT_EMOJI="🐙" ;;
    *) AGENT_EMOJI="$EMOJI_CHOICE" ;;  # Let them paste their own
  esac

  echo ""
  echo -e "${BOLD}What vibe should your agent have?${NC}"
  echo ""
  echo "  1) Professional — Direct, efficient, business-like"
  echo "  2) Friendly — Warm, conversational, approachable"
  echo "  3) Creative — Bold, expressive, thinks outside the box"
  echo "  4) Technical — Precise, detailed, loves data and specs"
  echo "  5) Witty — Clever, dry humor, personality-forward"
  echo "  6) Custom — You'll describe it yourself"
  echo ""
  ask "Agent personality [1-6]"
  read -r AGENT_VIBE_CHOICE
  AGENT_VIBE_CHOICE="${AGENT_VIBE_CHOICE:-2}"

  case "$AGENT_VIBE_CHOICE" in
    1) AGENT_VIBE="Professional — direct, efficient, no-nonsense. Gets to the point. Values clarity over charm." ;;
    2) AGENT_VIBE="Friendly — warm, conversational, approachable. Feels like talking to a helpful colleague who genuinely cares." ;;
    3) AGENT_VIBE="Creative — bold, expressive, thinks outside the box. Not afraid to suggest unexpected ideas or take creative risks." ;;
    4) AGENT_VIBE="Technical — precise, detailed, data-driven. Loves specs, accuracy, and thoroughness. Shows its work." ;;
    5) AGENT_VIBE="Witty — clever, dry humor, personality-forward. Smart and fun without being annoying. Knows when to be serious." ;;
    6)
      ask "Describe your agent's personality in a sentence or two"
      read -r AGENT_VIBE
      AGENT_VIBE="${AGENT_VIBE:-Helpful and adaptable}"
      ;;
    *) AGENT_VIBE="Friendly — warm, conversational, approachable." ;;
  esac

  echo ""
  ask "What's your agent's mission? (e.g., 'Help me build and ship software faster' or 'Manage my business operations') — or press Enter for default"
  read -r AGENT_MISSION
  AGENT_MISSION="${AGENT_MISSION:-Help ${USER_NAME} get things done efficiently and thoughtfully}"

  echo ""
  ask "Any specific skills or knowledge your agent should emphasize? (e.g., 'Python expert', 'knows real estate', 'marketing guru') — or press Enter to skip"
  read -r AGENT_EXPERTISE
  AGENT_EXPERTISE="${AGENT_EXPERTISE:-}"

  echo ""
  echo -e "${BOLD}--- Agent Tier ---${NC}"
  echo ""
  echo "  1) Solo     — Main agent only (simplest)"
  echo "  2) Team     — Main + Comms + Research agents"
  echo "  3) Squad    — Main + Comms + Research + Security agents"
  echo ""
  ask "Choose tier [1/2/3]"
  read -r TIER_CHOICE
  TIER_CHOICE="${TIER_CHOICE:-1}"

  # Interface choice
  echo ""
  echo -e "${BOLD}--- Interface ---${NC}"
  echo ""
  echo "  1) Discord           — Chat with your agents via Discord bot"
  echo "  2) ClawSuite Console  — Web dashboard with chat, file browser, terminal, cost analytics"
  echo "  3) Both              — Discord + ClawSuite Console side by side"
  echo ""
  ask "Choose interface [1/2/3]"
  read -r INTERFACE_CHOICE
  INTERFACE_CHOICE="${INTERFACE_CHOICE:-1}"

  USE_DISCORD=false
  USE_CONSOLE=false

  case "$INTERFACE_CHOICE" in
    2)
      USE_CONSOLE=true
      ;;
    3)
      USE_DISCORD=true
      USE_CONSOLE=true
      ;;
    *)
      USE_DISCORD=true
      ;;
  esac

  DEPLOY_COMMS=false
  DEPLOY_RESEARCH=false
  DEPLOY_SECURITY=false

  case "$TIER_CHOICE" in
    3)
      DEPLOY_COMMS=true
      DEPLOY_RESEARCH=true
      DEPLOY_SECURITY=true
      ;;
    2)
      DEPLOY_COMMS=true
      DEPLOY_RESEARCH=true
      ;;
    *)
      ;;
  esac

  # Collect specialist agent names if deploying
  if [ "$DEPLOY_COMMS" = true ]; then
    while true; do
      ask "Comms agent name (default: Knox)"
      read -r COMMS_NAME
      COMMS_NAME="${COMMS_NAME:-Knox}"
      if validate_name "$COMMS_NAME" "comms agent name" >/dev/null 2>&1; then break; fi
    done
  fi

  if [ "$DEPLOY_RESEARCH" = true ]; then
    while true; do
      ask "Research agent name (default: Trace)"
      read -r RESEARCH_NAME
      RESEARCH_NAME="${RESEARCH_NAME:-Trace}"
      if validate_name "$RESEARCH_NAME" "research agent name" >/dev/null 2>&1; then break; fi
    done
  fi

  if [ "$DEPLOY_SECURITY" = true ]; then
    while true; do
      ask "Security agent name (default: Sentinel)"
      read -r SECURITY_NAME
      SECURITY_NAME="${SECURITY_NAME:-Sentinel}"
      if validate_name "$SECURITY_NAME" "security agent name" >/dev/null 2>&1; then break; fi
    done
  fi

  echo ""
}

# ============================================================
# Collect API keys
# ============================================================

collect_keys() {
  echo -e "${BOLD}--- API Keys ---${NC}"
  echo ""
  info "Keys are stored in $ENV_FILE (gitignored, never committed)"
  echo ""

  # LLM Provider
  echo -e "${BOLD}LLM Provider:${NC}"
  echo ""
  echo "  ${BOLD}API Key providers:${NC}"
  echo "  1) OpenAI API"
  echo "  2) Anthropic API"
  echo "  3) Google Gemini API"
  echo "  4) OpenRouter (400+ models)"
  echo "  5) Kimi / Moonshot AI"
  echo ""
  echo "  ${BOLD}OAuth / subscription login (no API key needed):${NC}"
  echo "  6) GitHub Copilot (free with Copilot subscription)"
  echo "  7) OpenAI Codex OAuth (ChatGPT subscription)"
  echo "  8) Google Gemini CLI OAuth (Google account)"
  echo "  9) Anthropic Claude setup-token (Max subscription)"
  echo ""
  echo "  0) Other / manual config"
  echo ""
  ask "Choose provider [0-9]"
  read -r PROVIDER_CHOICE
  PROVIDER_CHOICE="${PROVIDER_CHOICE:-6}"

  case "$PROVIDER_CHOICE" in
    1)
      LLM_PROVIDER="openai"
      ask "OpenAI API key (sk-...)"
      read -rs OPENAI_DIRECT_KEY
      echo ""
      ;;
    2)
      LLM_PROVIDER="anthropic"
      ask "Anthropic API key (sk-ant-...)"
      read -rs ANTHROPIC_KEY
      echo ""
      ;;
    3)
      LLM_PROVIDER="gemini"
      ask "Google Gemini API key"
      read -rs GEMINI_KEY
      echo ""
      info "Get a free key at https://aistudio.google.com/apikey"
      ;;
    4)
      LLM_PROVIDER="openrouter"
      ask "OpenRouter API key (sk-or-...)"
      read -rs OPENROUTER_KEY
      echo ""
      info "Browse models at https://openrouter.ai/models"
      ;;
    5)
      LLM_PROVIDER="kimi"
      ask "Moonshot/Kimi API key"
      read -rs KIMI_KEY
      echo ""
      info "Get a key at https://platform.moonshot.ai"
      ;;
    6)
      LLM_PROVIDER="copilot"
      info "Copilot proxy will be configured on localhost:4141"
      info "Make sure copilot-api is running: npx copilot-api start --port 4141"
      COPILOT_API_KEY="copilot-proxy-local"
      ;;
    7)
      LLM_PROVIDER="openai-codex-oauth"
      info "After setup completes, you'll authenticate via browser OAuth."
      info "Requires an active ChatGPT Plus/Pro/Team subscription."
      OAUTH_DEFERRED="openai-codex"
      ;;
    8)
      LLM_PROVIDER="gemini-cli-oauth"
      info "After setup completes, you'll authenticate via browser OAuth."
      info "Uses your Google account — free tier available."
      warn "Unofficial integration. Use a non-critical Google account."
      OAUTH_DEFERRED="google-gemini-cli"
      ;;
    9)
      LLM_PROVIDER="anthropic-oauth"
      info "After setup completes, you'll authenticate via setup-token."
      info "Requires Claude Max/Team subscription."
      warn "Anthropic may restrict non-Claude usage. Check current terms."
      OAUTH_DEFERRED="anthropic"
      ;;
    0)
      LLM_PROVIDER="manual"
      warn "You'll need to configure the model provider in openclaw.json manually"
      ;;
  esac

  echo ""

  # Discord (only if using Discord interface)
  if [ "$USE_DISCORD" = true ]; then
    echo -e "${BOLD}Discord Setup:${NC}"
    echo ""
    info "You need a Discord server and bot. Here's how to set both up:"
    echo ""
    echo "  CREATE A SERVER (skip if you already have one):"
    echo "  ─────────────────────────────────────────────────"
    echo "  1. Open Discord → click the '+' button in the left sidebar"
    echo "  2. Choose 'Create My Own' → 'For me and my friends'"
    echo "  3. Name your server (e.g., 'My AI Agents') → Create"
    echo "  4. Create channels for your agents (e.g., #main, #research, #security)"
    echo "     Right-click 'Text Channels' → 'Create Channel' → name it → Create"
    echo ""
    echo "  CREATE A BOT:"
    echo "  ─────────────────────────────────────────────────"
    echo "  1. Go to https://discord.com/developers/applications"
    echo "  2. Click 'New Application' → name it → Create"
    echo "  3. Left sidebar → 'Bot' → 'Reset Token' → copy the token"
    echo "  4. On the Bot page, enable ALL THREE Privileged Gateway Intents:"
    echo "     ✅ Presence Intent  ✅ Server Members Intent  ✅ Message Content Intent"
    echo "  5. Left sidebar → 'OAuth2' → URL Generator"
    echo "     Scopes: bot  |  Permissions: Administrator (or Send/Read Messages + more)"
    echo "     Copy the URL → open in browser → select your server → Authorize"
    echo ""
    echo "  GET YOUR IDs:"
    echo "  ─────────────────────────────────────────────────"
    echo "  1. In Discord: Settings → Advanced → enable Developer Mode"
    echo "  2. Right-click server name → 'Copy Server ID'"
    echo "  3. Right-click your username → 'Copy User ID'"
    echo "  4. Right-click each channel → 'Copy Channel ID'"
    echo ""
    ask "Discord bot token"
    read -rs DISCORD_TOKEN
    echo ""

    while true; do
      ask "Discord guild (server) ID"
      read -r DISCORD_GUILD
      if validate_snowflake "$DISCORD_GUILD" "guild ID" >/dev/null 2>&1; then break; fi
    done

    while true; do
      ask "Your Discord user ID"
      read -r DISCORD_OWNER
      if validate_snowflake "$DISCORD_OWNER" "user ID" >/dev/null 2>&1; then break; fi
    done

    # Channel IDs
    while true; do
      ask "Main agent channel ID"
      read -r DISCORD_MAIN_CHANNEL
      if validate_snowflake "$DISCORD_MAIN_CHANNEL" "channel ID" >/dev/null 2>&1; then break; fi
    done

    if [ "$DEPLOY_COMMS" = true ]; then
      while true; do
        ask "Comms agent channel ID"
        read -r DISCORD_COMMS_CHANNEL
        if validate_snowflake "$DISCORD_COMMS_CHANNEL" "channel ID" >/dev/null 2>&1; then break; fi
      done
    fi

    if [ "$DEPLOY_RESEARCH" = true ]; then
      while true; do
        ask "Research agent channel ID"
        read -r DISCORD_RESEARCH_CHANNEL
        if validate_snowflake "$DISCORD_RESEARCH_CHANNEL" "channel ID" >/dev/null 2>&1; then break; fi
      done
    fi

    if [ "$DEPLOY_SECURITY" = true ]; then
      while true; do
        ask "Security agent channel ID"
        read -r DISCORD_SECURITY_CHANNEL
        if validate_snowflake "$DISCORD_SECURITY_CHANNEL" "channel ID" >/dev/null 2>&1; then break; fi
      done
    fi
  else
    DISCORD_TOKEN=""
    DISCORD_GUILD=""
    DISCORD_OWNER=""
    DISCORD_MAIN_CHANNEL=""
    DISCORD_COMMS_CHANNEL=""
    DISCORD_RESEARCH_CHANNEL=""
    DISCORD_SECURITY_CHANNEL=""
  fi

  # Default specialist names if not set (Solo tier)
  COMMS_NAME="${COMMS_NAME:-Knox}"
  RESEARCH_NAME="${RESEARCH_NAME:-Trace}"
  SECURITY_NAME="${SECURITY_NAME:-Sentinel}"

  echo ""

  # Brave Search
  echo -e "${BOLD}Web Search (optional):${NC}"
  ask "Brave Search API key (press Enter to skip)"
  read -rs BRAVE_KEY
  echo ""

  # OpenAI for skills/embeddings
  if [ "$LLM_PROVIDER" != "openai" ]; then
    echo ""
    echo -e "${BOLD}OpenAI (for image gen / whisper / embeddings — optional):${NC}"
    ask "OpenAI API key (press Enter to skip)"
    read -rs OPENAI_SKILLS_KEY
    echo ""
  else
    OPENAI_SKILLS_KEY="$OPENAI_DIRECT_KEY"
  fi

  # ElevenLabs
  echo ""
  echo -e "${BOLD}ElevenLabs TTS (optional):${NC}"
  ask "ElevenLabs API key (press Enter to skip)"
  read -rs ELEVENLABS_KEY
  echo ""

  echo ""
}

# ============================================================
# Generate .env file
# ============================================================

generate_env() {
  info "Generating $ENV_FILE..."

  # Security: check for symlink attacks
  safe_write_check "$ENV_FILE"

  GATEWAY_TOKEN=$(random_token)

  # Create file with restricted permissions first, then write
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  cat > "$ENV_FILE" << ENVEOF
# ============================================================
# Clawdboss Environment — Generated $(date +%Y-%m-%d)
# DO NOT COMMIT THIS FILE
# ============================================================

# LLM Provider
COPILOT_API_KEY=${COPILOT_API_KEY:-}
ENVEOF

  if [ "$LLM_PROVIDER" = "openai" ]; then
    echo "OPENAI_API_KEY=${OPENAI_DIRECT_KEY}" >> "$ENV_FILE"
  elif [ "$LLM_PROVIDER" = "anthropic" ]; then
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_KEY}" >> "$ENV_FILE"
  elif [ "$LLM_PROVIDER" = "gemini" ]; then
    echo "GEMINI_API_KEY=${GEMINI_KEY}" >> "$ENV_FILE"
  elif [ "$LLM_PROVIDER" = "openrouter" ]; then
    echo "OPENROUTER_API_KEY=${OPENROUTER_KEY}" >> "$ENV_FILE"
  elif [ "$LLM_PROVIDER" = "kimi" ]; then
    echo "KIMI_API_KEY=${KIMI_KEY}" >> "$ENV_FILE"
  fi

  if [ "$USE_DISCORD" = true ]; then
    cat >> "$ENV_FILE" << ENVEOF

# Discord
DISCORD_BOT_TOKEN=${DISCORD_TOKEN}
ENVEOF
  fi

  cat >> "$ENV_FILE" << ENVEOF

# Web Search
BRAVE_API_KEY=${BRAVE_KEY:-}

# Skills
OPENAI_API_KEY=${OPENAI_SKILLS_KEY:-}
ELEVENLABS_API_KEY=${ELEVENLABS_KEY:-}

# Embeddings (memory-hybrid)
EMBEDDING_API_KEY=${OPENAI_SKILLS_KEY:-}

# Gateway
GATEWAY_AUTH_TOKEN=${GATEWAY_TOKEN}
ENVEOF

  success "Environment file created (permissions: 600)"
}

# ============================================================
# Generate openclaw.json from template
# ============================================================

generate_config() {
  info "Generating $CONFIG_FILE..."

  # Security: check for symlink attacks
  safe_write_check "$CONFIG_FILE"

  local WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
  mkdir -p "$WORKSPACE_DIR"

  # Pass all user inputs as environment variables to Python (not bash substitution)
  # This prevents shell injection via the Python heredoc
  export CB_TEMPLATES_DIR="$TEMPLATES_DIR"
  export CB_WORKSPACE_DIR="$WORKSPACE_DIR"
  export CB_OPENCLAW_DIR="$OPENCLAW_DIR"
  export CB_DISCORD_GUILD="${DISCORD_GUILD:-}"
  export CB_DISCORD_OWNER="${DISCORD_OWNER:-}"
  export CB_DISCORD_MAIN_CHANNEL="${DISCORD_MAIN_CHANNEL:-}"
  export CB_DEPLOY_COMMS="$DEPLOY_COMMS"
  export CB_DEPLOY_RESEARCH="$DEPLOY_RESEARCH"
  export CB_DEPLOY_SECURITY="$DEPLOY_SECURITY"
  export CB_LLM_PROVIDER="$LLM_PROVIDER"
  export CB_OPENAI_SKILLS_KEY="${OPENAI_SKILLS_KEY:-}"
  export CB_ELEVENLABS_KEY="${ELEVENLABS_KEY:-}"
  export CB_BRAVE_KEY="${BRAVE_KEY:-}"
  export CB_USE_DISCORD="$USE_DISCORD"
  export CB_USE_CONSOLE="$USE_CONSOLE"

  # Only export specialist names/channels if deploying
  if [ "$DEPLOY_COMMS" = true ]; then
    export CB_COMMS_NAME="$COMMS_NAME"
    export CB_DISCORD_COMMS_CHANNEL="$DISCORD_COMMS_CHANNEL"
  fi
  if [ "$DEPLOY_RESEARCH" = true ]; then
    export CB_RESEARCH_NAME="$RESEARCH_NAME"
    export CB_DISCORD_RESEARCH_CHANNEL="$DISCORD_RESEARCH_CHANNEL"
  fi
  if [ "$DEPLOY_SECURITY" = true ]; then
    export CB_SECURITY_NAME="$SECURITY_NAME"
    export CB_DISCORD_SECURITY_CHANNEL="$DISCORD_SECURITY_CHANNEL"
  fi

  # Use single-quoted PYEOF to prevent ALL bash substitution in the heredoc
  python3 << 'PYEOF' > "$CONFIG_FILE"
import json, os

templates_dir = os.environ['CB_TEMPLATES_DIR']
workspace_dir = os.environ['CB_WORKSPACE_DIR']
openclaw_dir = os.environ['CB_OPENCLAW_DIR']
guild_id = os.environ.get('CB_DISCORD_GUILD', '')
owner_id = os.environ.get('CB_DISCORD_OWNER', '')
main_channel = os.environ.get('CB_DISCORD_MAIN_CHANNEL', '')
deploy_comms = os.environ['CB_DEPLOY_COMMS'] == 'true'
deploy_research = os.environ['CB_DEPLOY_RESEARCH'] == 'true'
deploy_security = os.environ['CB_DEPLOY_SECURITY'] == 'true'
use_discord = os.environ.get('CB_USE_DISCORD', 'true') == 'true'
use_console = os.environ.get('CB_USE_CONSOLE', 'false') == 'true'
llm_provider = os.environ['CB_LLM_PROVIDER']
openai_skills_key = os.environ.get('CB_OPENAI_SKILLS_KEY', '')
elevenlabs_key = os.environ.get('CB_ELEVENLABS_KEY', '')
brave_key = os.environ.get('CB_BRAVE_KEY', '')

with open(os.path.join(templates_dir, "openclaw.template.json")) as f:
    config = json.load(f)

# Fix workspace
config['agents']['list'][0]['workspace'] = workspace_dir

# Discord config (only if using Discord)
if use_discord and guild_id and owner_id:
    config['channels']['discord']['allowFrom'] = [owner_id]
    config['channels']['discord']['execApprovals']['approvers'] = [owner_id]

    config['channels']['discord']['guilds'] = {
        guild_id: {
            "requireMention": False,
            "users": [owner_id],
            "channels": {
                main_channel: {"allow": True}
            }
        }
    }

    # Fix bindings
    config['bindings'] = [{
        "agentId": "main",
        "match": {"channel": "discord", "guildId": guild_id}
    }]
else:
    # No Discord — remove discord channel config, use dashboard only
    if 'discord' in config.get('channels', {}):
        del config['channels']['discord']
    config['bindings'] = []

# Agent allow list
allow_agents = ["main"]

# Specialist agents
if deploy_comms:
    comms_name = os.environ.get('CB_COMMS_NAME', 'Knox')
    comms_channel = os.environ.get('CB_DISCORD_COMMS_CHANNEL', '')
    comms_id = comms_name.lower().replace(' ', '-')
    comms_workspace = os.path.join(openclaw_dir, f"workspace-{comms_id}")
    allow_agents.append(comms_id)

    config['agents']['list'].append({
        "id": comms_id,
        "name": comms_name,
        "workspace": comms_workspace,
        "agentDir": os.path.join(openclaw_dir, "agents", comms_id, "agent"),
        "model": {"primary": "copilot/claude-sonnet-4.5"},
        "identity": {"name": comms_name, "emoji": "\U0001f4e1"}
    })

    config['bindings'].insert(0, {
        "agentId": comms_id,
        "match": {"channel": "discord", "peer": {"kind": "channel", "id": comms_channel}}
    })

    if use_discord and guild_id:
        config['channels']['discord']['guilds'][guild_id]['channels'][comms_channel] = {"allow": True}

if deploy_research:
    research_name = os.environ.get('CB_RESEARCH_NAME', 'Trace')
    research_channel = os.environ.get('CB_DISCORD_RESEARCH_CHANNEL', '')
    research_id = research_name.lower().replace(' ', '-')
    research_workspace = os.path.join(openclaw_dir, f"workspace-{research_id}")
    allow_agents.append(research_id)

    config['agents']['list'].append({
        "id": research_id,
        "name": research_name,
        "workspace": research_workspace,
        "agentDir": os.path.join(openclaw_dir, "agents", research_id, "agent"),
        "model": {"primary": "copilot/claude-sonnet-4.5"},
        "identity": {"name": research_name, "emoji": "\U0001f50d"}
    })

    config['bindings'].insert(0, {
        "agentId": research_id,
        "match": {"channel": "discord", "peer": {"kind": "channel", "id": research_channel}}
    })

    if use_discord and guild_id:
        config['channels']['discord']['guilds'][guild_id]['channels'][research_channel] = {"allow": True}

if deploy_security:
    security_name = os.environ.get('CB_SECURITY_NAME', 'Sentinel')
    security_channel = os.environ.get('CB_DISCORD_SECURITY_CHANNEL', '')
    security_id = security_name.lower().replace(' ', '-')
    security_workspace = os.path.join(openclaw_dir, f"workspace-{security_id}")
    allow_agents.append(security_id)

    config['agents']['list'].append({
        "id": security_id,
        "name": security_name,
        "workspace": security_workspace,
        "agentDir": os.path.join(openclaw_dir, "agents", security_id, "agent"),
        "model": {"primary": "copilot/claude-sonnet-4.5"},
        "identity": {"name": security_name, "emoji": "\U0001f6e1\ufe0f"}
    })

    config['bindings'].insert(0, {
        "agentId": security_id,
        "match": {"channel": "discord", "peer": {"kind": "channel", "id": security_channel}}
    })

    if use_discord and guild_id:
        config['channels']['discord']['guilds'][guild_id]['channels'][security_channel] = {"allow": True}

# Set allow lists
config['agents']['list'][0]['subagents']['allowAgents'] = allow_agents

if len(allow_agents) > 1:
    config['tools']['agentToAgent'] = {
        "enabled": True,
        "allow": allow_agents
    }

# LLM provider config
if llm_provider == "openai":
    config['models']['providers'] = {
        "openai": {
            "baseUrl": "https://api.openai.com/v1",
            "apiKey": "${OPENAI_API_KEY}",
            "models": [
                {"id": "gpt-4.1", "name": "GPT-4.1", "input": ["text", "image"], "contextWindow": 1047576, "maxTokens": 32768},
                {"id": "gpt-4.1-mini", "name": "GPT-4.1 Mini", "input": ["text", "image"], "contextWindow": 1047576, "maxTokens": 32768},
                {"id": "gpt-4.1-nano", "name": "GPT-4.1 Nano", "input": ["text", "image"], "contextWindow": 1047576, "maxTokens": 32768},
                {"id": "gpt-4o", "name": "GPT-4o", "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 16384}
            ]
        }
    }
    config['agents']['defaults']['model']['primary'] = "openai/gpt-4.1"
    config['agents']['defaults']['heartbeat']['model'] = "openai/gpt-4.1-mini"
elif llm_provider == "anthropic":
    config['models']['providers'] = {
        "anthropic": {
            "baseUrl": "https://api.anthropic.com",
            "apiKey": "${ANTHROPIC_API_KEY}",
            "models": [
                {"id": "claude-sonnet-4-5-20250514", "name": "Claude Sonnet 4.5", "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 16384}
            ]
        }
    }
    config['agents']['defaults']['model']['primary'] = "anthropic/claude-sonnet-4-5-20250514"
elif llm_provider == "gemini":
    config['models']['providers'] = {
        "google": {
            "baseUrl": "https://generativelanguage.googleapis.com/v1beta",
            "apiKey": "${GEMINI_API_KEY}",
            "api": "google-generative-ai",
            "models": [
                {"id": "gemini-2.5-pro", "name": "Gemini 2.5 Pro", "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 65536},
                {"id": "gemini-2.5-flash", "name": "Gemini 2.5 Flash", "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 65536}
            ]
        }
    }
    config['agents']['defaults']['model']['primary'] = "google/gemini-2.5-pro"
    config['agents']['defaults']['heartbeat']['model'] = "google/gemini-2.5-flash"
elif llm_provider == "openrouter":
    config['models']['providers'] = {
        "openrouter": {
            "baseUrl": "https://openrouter.ai/api/v1",
            "apiKey": "${OPENROUTER_API_KEY}",
            "api": "openai-completions",
            "models": [
                {"id": "anthropic/claude-sonnet-4", "name": "Claude Sonnet 4 (OpenRouter)", "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 16384},
                {"id": "openai/gpt-4o", "name": "GPT-4o (OpenRouter)", "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 16384},
                {"id": "google/gemini-2.5-pro-preview", "name": "Gemini 2.5 Pro (OpenRouter)", "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 65536}
            ]
        }
    }
    config['agents']['defaults']['model']['primary'] = "openrouter/anthropic/claude-sonnet-4"
    config['agents']['defaults']['heartbeat']['model'] = "openrouter/openai/gpt-4o"
elif llm_provider == "kimi":
    config['models']['providers'] = {
        "kimi": {
            "baseUrl": "https://api.moonshot.cn/v1",
            "apiKey": "${KIMI_API_KEY}",
            "api": "openai-completions",
            "models": [
                {"id": "kimi-k2", "name": "Kimi K2", "input": ["text", "image"], "contextWindow": 131072, "maxTokens": 16384},
                {"id": "moonshot-v1-128k", "name": "Moonshot v1 128K", "input": ["text"], "contextWindow": 131072, "maxTokens": 16384}
            ]
        }
    }
    config['agents']['defaults']['model']['primary'] = "kimi/kimi-k2"
    config['agents']['defaults']['heartbeat']['model'] = "kimi/moonshot-v1-128k"
elif llm_provider == "openai-codex-oauth":
    # No provider config needed — built-in pi-ai catalog handles it
    # OAuth login happens post-setup via openclaw models auth login
    config['agents']['defaults']['model']['primary'] = "openai-codex/gpt-4.1"
elif llm_provider == "gemini-cli-oauth":
    # OAuth login happens post-setup via openclaw models auth login
    config['agents']['defaults']['model']['primary'] = "google-gemini-cli/gemini-2.5-pro"
    config['agents']['defaults']['heartbeat']['model'] = "google-gemini-cli/gemini-2.5-flash"
elif llm_provider == "anthropic-oauth":
    # Setup-token login happens post-setup via openclaw models auth
    config['agents']['defaults']['model']['primary'] = "anthropic/claude-sonnet-4-5-20250514"

# Skills with keys
if openai_skills_key:
    config['skills']['entries']['openai-image-gen'] = {"apiKey": "${OPENAI_API_KEY}"}
    config['skills']['entries']['openai-whisper-api'] = {"apiKey": "${OPENAI_API_KEY}"}
    # If not using OpenAI as LLM provider, add a minimal openai provider for skills
    if llm_provider != "openai" and "openai" not in config.get('models', {}).get('providers', {}):
        config.setdefault('models', {}).setdefault('providers', {})['openai'] = {
            "baseUrl": "https://api.openai.com/v1",
            "apiKey": "${OPENAI_API_KEY}",
            "models": []
        }
if elevenlabs_key:
    config['skills']['entries']['sag'] = {"apiKey": "${ELEVENLABS_API_KEY}"}

# Brave Search (only if key provided)
if brave_key:
    config['tools']['web']['search'] = {"enabled": True, "apiKey": "${BRAVE_API_KEY}"}

print(json.dumps(config, indent=2))
PYEOF

  chmod 600 "$CONFIG_FILE"
  success "Config generated with \${VAR} references (permissions: 600)"

  # Clean up exported vars
  unset CB_TEMPLATES_DIR CB_WORKSPACE_DIR CB_OPENCLAW_DIR CB_DISCORD_GUILD CB_DISCORD_OWNER
  unset CB_DISCORD_MAIN_CHANNEL CB_DEPLOY_COMMS CB_DEPLOY_RESEARCH CB_DEPLOY_SECURITY
  unset CB_LLM_PROVIDER CB_OPENAI_SKILLS_KEY CB_ELEVENLABS_KEY CB_BRAVE_KEY
  unset CB_COMMS_NAME CB_DISCORD_COMMS_CHANNEL CB_RESEARCH_NAME CB_DISCORD_RESEARCH_CHANNEL
  unset CB_SECURITY_NAME CB_DISCORD_SECURITY_CHANNEL 2>/dev/null || true
}

# ============================================================
# Deploy workspace files
# ============================================================

deploy_workspaces() {
  info "Deploying workspace files..."

  local WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
  mkdir -p "$WORKSPACE_DIR/memory"
  mkdir -p "$WORKSPACE_DIR/reference"

  # Main workspace — copy and personalize using Python for safe substitution
  for f in AGENTS.md SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md; do
    if [ -f "$TEMPLATES_DIR/workspace/$f" ]; then
      python3 -c "
import sys, re
content = open(sys.argv[1]).read()

# Basic replacements
replacements = {
    '__AGENT_NAME__': sys.argv[3],
    '__AGENT_PRONOUNS__': sys.argv[4],
    '__AGENT_EMOJI__': sys.argv[5],
    '__USER_NAME__': sys.argv[6],
    '__USER_TIMEZONE__': sys.argv[7],
    '__USER_PRONOUNS__': sys.argv[8],
    '__AGENT_VIBE__': sys.argv[9],
    '__AGENT_MISSION__': sys.argv[10],
    '__USER_USECASE__': sys.argv[11],
}
for k, v in replacements.items():
    content = content.replace(k, v)

# Conditional blocks — only show sections with content
user_location = sys.argv[12]
user_role = sys.argv[13]
user_desc = sys.argv[14]
agent_expertise = sys.argv[15]
user_extra = sys.argv[16]

content = content.replace('__USER_LOCATION_LINE__', f'- **Location:** {user_location}' if user_location else '')

# Build background block
bg_parts = []
if user_role: bg_parts.append(f'**Role:** {user_role}')
if user_desc: bg_parts.append(user_desc)
if bg_parts:
    content = content.replace('__USER_BACKGROUND_BLOCK__', '## Background\n\n' + '\n'.join(bg_parts))
else:
    content = content.replace('__USER_BACKGROUND_BLOCK__', '')

content = content.replace('__AGENT_EXPERTISE_BLOCK__', f'**Domain expertise:** {agent_expertise}' if agent_expertise else '')
content = content.replace('__USER_EXTRA_BLOCK__', f'## Extra Context\n\n{user_extra}' if user_extra else '')

# Clean up blank lines from empty blocks
content = re.sub(r'\n{3,}', '\n\n', content)

open(sys.argv[2], 'w').write(content)
" "$TEMPLATES_DIR/workspace/$f" "$WORKSPACE_DIR/$f" \
  "$AGENT_NAME" "$AGENT_PRONOUNS" "$AGENT_EMOJI" \
  "$USER_NAME" "$USER_TIMEZONE" "${USER_PRONOUNS:-they/them}" \
  "$AGENT_VIBE" "$AGENT_MISSION" "$USER_USECASE" \
  "${USER_LOCATION:-}" "$USER_ROLE" "${USER_DESCRIPTION:-}" "${AGENT_EXPERTISE:-}" "${USER_EXTRA:-}"
    fi
  done

  # Create WAL Protocol files (SESSION-STATE.md + working-buffer.md)
  cat > "$WORKSPACE_DIR/SESSION-STATE.md" << 'WALEOF'
# SESSION-STATE.md — Active Working Memory

**Last Updated:** —
**Active Task:** —
**Status:** idle

## Corrections / Decisions
_(Capture every correction, decision, preference, proper noun here BEFORE responding)_

## Active Details
_(Names, IDs, URLs, values that matter for the current task)_

## Draft State
_(If working on something iterative — current version lives here)_
WALEOF

  cat > "$WORKSPACE_DIR/memory/working-buffer.md" << 'BUFEOF'
# Working Buffer (Danger Zone Log)

**Status:** INACTIVE
**Started:** —

_(This buffer activates when context hits ~60%. Every exchange after that point gets logged here to survive compaction.)_

---
BUFEOF

  success "Main workspace: $WORKSPACE_DIR"

  # Deploy specialist workspaces
  deploy_specialist_workspace() {
    local agent_name="$1"
    local agent_type="$2"  # comms, research, security

    # Use bash parameter expansion for lowercase (no external commands)
    local agent_id="${agent_name,,}"
    # Replace spaces with hyphens
    agent_id="${agent_id// /-}"

    # Validate the ID
    agent_id=$(validate_agent_id "$agent_id") || { error "Invalid agent name produced invalid ID"; exit 1; }

    local agent_ws="$OPENCLAW_DIR/workspace-$agent_id"

    # Validate path is under OPENCLAW_DIR
    validate_path_under "$agent_ws" "$OPENCLAW_DIR" >/dev/null || { error "Path traversal detected"; exit 1; }

    mkdir -p "$agent_ws/memory"
    mkdir -p "$agent_ws/reference"
    mkdir -p "$OPENCLAW_DIR/agents/$agent_id/agent"

    cp "$TEMPLATES_DIR/workspace/AGENTS.md" "$agent_ws/AGENTS.md"

    # Safe substitution via Python
    python3 -c "
import sys
content = open(sys.argv[1]).read()
content = content.replace('__AGENT_NAME__', sys.argv[3])
open(sys.argv[2], 'w').write(content)
" "$TEMPLATES_DIR/agents/$agent_type/SOUL.md" "$agent_ws/SOUL.md" "$agent_name"

    python3 -c "
import sys, re
content = open(sys.argv[1]).read()
replacements = {
    '__USER_NAME__': sys.argv[3],
    '__USER_TIMEZONE__': sys.argv[4],
    '__USER_PRONOUNS__': sys.argv[5],
    '__USER_USECASE__': sys.argv[6],
}
for k, v in replacements.items():
    content = content.replace(k, v)

user_location = sys.argv[7]
user_role = sys.argv[8]
user_desc = sys.argv[9]
user_extra = sys.argv[10]

content = content.replace('__USER_LOCATION_LINE__', f'- **Location:** {user_location}' if user_location else '')

bg_parts = []
if user_role: bg_parts.append(f'**Role:** {user_role}')
if user_desc: bg_parts.append(user_desc)
if bg_parts:
    content = content.replace('__USER_BACKGROUND_BLOCK__', '## Background\n\n' + '\n'.join(bg_parts))
else:
    content = content.replace('__USER_BACKGROUND_BLOCK__', '')

content = content.replace('__USER_EXTRA_BLOCK__', f'## Extra Context\n\n{user_extra}' if user_extra else '')

content = re.sub(r'\n{3,}', '\n\n', content)
open(sys.argv[2], 'w').write(content)
" "$TEMPLATES_DIR/workspace/USER.md" "$agent_ws/USER.md" \
  "$USER_NAME" "$USER_TIMEZONE" "${USER_PRONOUNS:-they/them}" \
  "$USER_USECASE" "${USER_LOCATION:-}" "$USER_ROLE" "${USER_DESCRIPTION:-}" "${USER_EXTRA:-}"

    cp "$TEMPLATES_DIR/workspace/TOOLS.md" "$agent_ws/TOOLS.md"

    # Create WAL Protocol files for specialist agents too
    cat > "$agent_ws/SESSION-STATE.md" << 'WALEOF'
# SESSION-STATE.md — Active Working Memory

**Last Updated:** —
**Active Task:** —
**Status:** idle

## Corrections / Decisions
_(Capture every correction, decision, preference, proper noun here BEFORE responding)_

## Active Details
_(Names, IDs, URLs, values that matter for the current task)_

## Draft State
_(If working on something iterative — current version lives here)_
WALEOF

    cat > "$agent_ws/memory/working-buffer.md" << 'BUFEOF'
# Working Buffer (Danger Zone Log)

**Status:** INACTIVE
**Started:** —

_(This buffer activates when context hits ~60%. Every exchange after that point gets logged here to survive compaction.)_

---
BUFEOF

    success "$agent_type workspace: $agent_ws"
  }

  if [ "$DEPLOY_COMMS" = true ]; then
    deploy_specialist_workspace "$COMMS_NAME" "comms"
  fi

  if [ "$DEPLOY_RESEARCH" = true ]; then
    deploy_specialist_workspace "$RESEARCH_NAME" "research"
  fi

  if [ "$DEPLOY_SECURITY" = true ]; then
    deploy_specialist_workspace "$SECURITY_NAME" "security"
  fi
}

# ============================================================
# Install OCTAVE MCP server
# ============================================================

install_octave() {
  echo ""
  echo -e "${BOLD}--- OCTAVE Protocol (Optional) ---${NC}"
  echo ""
  info "OCTAVE is a structured document format for LLM communication."
  info "It provides 3-20x token compression, schema validation, and"
  info "deterministic artifacts for multi-agent handoffs and audit trails."
  echo ""
  ask "Install OCTAVE MCP server? [Y/n]"
  read -r INSTALL_OCTAVE
  INSTALL_OCTAVE="${INSTALL_OCTAVE:-Y}"

  if [[ ! "$INSTALL_OCTAVE" =~ ^[Yy] ]]; then
    info "Skipping OCTAVE installation."
    return
  fi

  local OCTAVE_VENV="$HOME/.octave-venv"

  if command -v uv &>/dev/null; then
    info "Installing OCTAVE via uv..."
    uv venv --clear "$OCTAVE_VENV" 2>/dev/null
    source "$OCTAVE_VENV/bin/activate" 2>/dev/null || true
    uv pip install octave-mcp 2>&1 | tail -1
  elif python3 -m venv --help &>/dev/null 2>&1; then
    # Ensure python3-venv is available (Ubuntu/Debian need it separately)
    if ! python3 -c "import ensurepip" &>/dev/null; then
      info "Installing python3-venv (required for virtual environments)..."
      apt-get install -y python3-venv 2>/dev/null \
        || apt-get install -y "python3.$(python3 -c 'import sys;print(sys.version_info.minor)')-venv" 2>/dev/null \
        || { warn "Could not install python3-venv. Run: sudo apt install python3-venv"; return; }
    fi
    info "Installing OCTAVE via python3 venv..."
    python3 -m venv "$OCTAVE_VENV"
    "$OCTAVE_VENV/bin/pip" install --quiet octave-mcp 2>&1
  else
    warn "Cannot install OCTAVE — neither uv nor python3-venv found."
    warn "Install manually: uv venv ~/.octave-venv && uv pip install octave-mcp"
    return
  fi

  if [ ! -f "$OCTAVE_VENV/bin/octave-mcp-server" ]; then
    warn "OCTAVE installation failed — binary not found. Skipping."
    return
  fi

  register_mcp "octave" "$OCTAVE_VENV/bin/octave-mcp-server"
  success "OCTAVE installed: $OCTAVE_VENV/bin/octave-mcp-server"
}

# ============================================================
# Install Graphthulhu — Knowledge Graph MCP
# ============================================================

install_graphthulhu() {
  echo ""
  echo -e "${BOLD}--- Graphthulhu — Knowledge Graph (Optional) ---${NC}"
  echo ""
  info "Typed knowledge graph for structured agent memory."
  info "Entities (Person, Project, Task, Event), relationships, constraints."
  info "Uses an Obsidian-compatible markdown vault (no Obsidian app required)."
  info "Shared knowledge base across all agents."
  echo ""
  ask "Install Graphthulhu? [Y/n]"
  read -r INSTALL_GRAPHTHULHU
  INSTALL_GRAPHTHULHU="${INSTALL_GRAPHTHULHU:-Y}"

  if [[ ! "$INSTALL_GRAPHTHULHU" =~ ^[Yy] ]]; then
    info "Skipping Graphthulhu."
    return
  fi

  local VAULT_DIR="$OPENCLAW_DIR/vault"
  mkdir -p "$VAULT_DIR"

  # Try go install first, then check for pre-built binary
  if command -v go &>/dev/null; then
    info "Installing Graphthulhu via go..."
    go install github.com/skridlevsky/graphthulhu@latest 2>&1 | tail -3 \
      && success "Graphthulhu installed via go" \
      || warn "Go install failed — trying binary download"
  fi

  if ! command -v graphthulhu &>/dev/null; then
    # Try downloading pre-built binary from GitHub releases
    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64) ARCH="amd64" ;;
      aarch64) ARCH="arm64" ;;
    esac
    local OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')

    info "Downloading Graphthulhu binary..."
    local RELEASE_URL="https://github.com/skridlevsky/graphthulhu/releases/download/v0.4.0/graphthulhu_0.4.0_${OS}_${ARCH}.tar.gz"
    local BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"

    if curl -fsSL -o /tmp/graphthulhu.tar.gz "$RELEASE_URL" 2>/dev/null; then
      (cd /tmp && tar xzf graphthulhu.tar.gz && mv graphthulhu "$BIN_DIR/" && chmod +x "$BIN_DIR/graphthulhu")
      success "Graphthulhu binary downloaded to $BIN_DIR/graphthulhu"
      rm -f /tmp/graphthulhu.tar.gz
    else
      warn "Could not download Graphthulhu. Install manually:"
      warn "  go install github.com/skridlevsky/graphthulhu@latest"
      warn "  OR download from: https://github.com/skridlevsky/graphthulhu/releases"
      return
    fi
  fi

  # Default to Obsidian backend — reads .md files directly, no Obsidian app needed
  register_mcp "graphthulhu" "graphthulhu serve --backend obsidian --vault $VAULT_DIR"
  success "Graphthulhu configured with Obsidian vault: $VAULT_DIR"
  info "Vault location: $VAULT_DIR (compatible with Obsidian app if you want to browse it)"
}

# ============================================================
# Install ApiTap — API Traffic Interception MCP
# ============================================================

install_apitap() {
  echo ""
  echo -e "${BOLD}--- ApiTap — API Discovery (Optional) ---${NC}"
  echo ""
  info "Intercepts web API traffic during browsing."
  info "Generates portable skill files so agents can call APIs"
  info "directly instead of scraping — headless API discovery."
  echo ""
  ask "Install ApiTap? [Y/n]"
  read -r INSTALL_APITAP
  INSTALL_APITAP="${INSTALL_APITAP:-Y}"

  if [[ ! "$INSTALL_APITAP" =~ ^[Yy] ]]; then
    info "Skipping ApiTap."
    return
  fi

  if npm install -g @apitap/core 2>&1 | tail -3; then
    register_mcp "apitap" "apitap-mcp"
    success "ApiTap installed (npm global: @apitap/core)"
  else
    warn "Could not install ApiTap. Install manually: npm install -g @apitap/core"
  fi
}

# ============================================================
# Install Scrapling — Anti-Bot Web Scraping
# ============================================================

install_scrapling() {
  echo ""
  echo -e "${BOLD}--- Scrapling — Web Scraping (Optional) ---${NC}"
  echo ""
  info "High-performance Python web scraping with anti-bot bypass."
  info "Adaptive selectors that survive site redesigns."
  info "Structured data extraction from JS-rendered pages."
  echo ""
  ask "Install Scrapling? [Y/n]"
  read -r INSTALL_SCRAPLING
  INSTALL_SCRAPLING="${INSTALL_SCRAPLING:-Y}"

  if [[ ! "$INSTALL_SCRAPLING" =~ ^[Yy] ]]; then
    info "Skipping Scrapling."
    return
  fi

  local PIP_CMD
  PIP_CMD="$(command -v pip3 || command -v pip)"
  if [ -n "$PIP_CMD" ]; then
    info "Installing Scrapling and dependencies..."
    "$PIP_CMD" install --break-system-packages scrapling curl_cffi browserforge 2>/dev/null \
      || "$PIP_CMD" install --user scrapling curl_cffi browserforge 2>/dev/null \
      || { warn "Could not install Scrapling. Install manually: pip install scrapling curl_cffi browserforge"; return; }

    # Install Playwright browsers for Scrapling's StealthyFetcher/PlayWrightFetcher
    info "Installing Playwright and Chromium browser..."
    "$PIP_CMD" install --break-system-packages playwright 2>/dev/null \
      || "$PIP_CMD" install --user playwright 2>/dev/null \
      || warn "Could not install playwright Python package"

    # Install Chromium browser binary
    python3 -m playwright install chromium 2>/dev/null \
      && success "Chromium browser installed for Scrapling" \
      || warn "Could not install Chromium. Run manually: python3 -m playwright install chromium"

    # Install system dependencies for Chromium (headless)
    if command -v apt-get &>/dev/null; then
      python3 -m playwright install-deps chromium 2>/dev/null \
        || warn "Could not install Chromium system deps. Run: python3 -m playwright install-deps chromium"
    fi

    success "Scrapling installed with all dependencies"
  else
    warn "pip not found. Install manually: pip install scrapling curl_cffi browserforge playwright"
  fi
}

# ============================================================
# Install GitHub skill
# ============================================================

install_github_skill() {
  echo ""
  echo -e "${BOLD}--- GitHub Integration (Optional) ---${NC}"
  echo ""
  info "Manage issues, PRs, CI runs, and code search via gh CLI."
  info "Essential for any development workflow."
  echo ""
  ask "Install GitHub skill? [Y/n]"
  read -r INSTALL_GITHUB
  INSTALL_GITHUB="${INSTALL_GITHUB:-Y}"

  if [[ ! "$INSTALL_GITHUB" =~ ^[Yy] ]]; then
    info "Skipping GitHub skill."
    return
  fi

  # Install gh CLI if not present
  if ! command -v gh &>/dev/null; then
    info "Installing GitHub CLI (gh)..."
    if command -v apt-get &>/dev/null; then
      (type -p wget >/dev/null || apt-get install wget -y -qq) \
        && mkdir -p -m 755 /etc/apt/keyrings \
        && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && apt-get update -qq && apt-get install gh -y -qq \
      || warn "Could not install gh CLI automatically. Install manually: https://cli.github.com"
    else
      warn "Install gh CLI manually: https://cli.github.com"
    fi
  fi

  # Install the OpenClaw GitHub skill
  npx --yes clawhub@latest --workdir "$OPENCLAW_DIR/workspace" install github \
    && success "GitHub skill installed" \
    || { info "clawhub install failed — copying from bundled skills"; }

  command -v gh &>/dev/null && success "gh CLI available" || warn "gh CLI not found — install from https://cli.github.com"
}

# ============================================================
# Install Humanizer — AI Writing De-AIification
# ============================================================

install_humanizer() {
  echo ""
  echo -e "${BOLD}--- Humanizer — Natural Writing (Optional) ---${NC}"
  echo ""
  info "Detects and removes signs of AI-generated writing."
  info "Scans for 24 AI patterns, 500+ vocabulary terms, and applies safe auto-replacements."
  echo ""
  ask "Install Humanizer? [Y/n]"
  read -r INSTALL_HUMANIZER
  INSTALL_HUMANIZER="${INSTALL_HUMANIZER:-Y}"

  if [[ ! "$INSTALL_HUMANIZER" =~ ^[Yy] ]]; then
    info "Skipping Humanizer."
    return
  fi

  if npx --yes clawhub@latest --workdir "$OPENCLAW_DIR/workspace" install humanizer; then
    success "Humanizer skill installed"
  else
    # Fallback to git clone
    SKILLS_DIR="$OPENCLAW_DIR/workspace/skills"
    mkdir -p "$SKILLS_DIR"
    if git clone --depth 1 https://github.com/brandonwise/humanizer.git "$SKILLS_DIR/humanizer" 2>/dev/null; then
      success "Humanizer installed from GitHub"
    else
      warn "Could not install Humanizer. Install manually: clawhub install humanizer"
    fi
  fi
}

# ============================================================
# Install Self-Improving Agent — Continuous Learning
# ============================================================

install_self_improving() {
  echo ""
  echo -e "${BOLD}--- Self-Improving Agent — Continuous Learning (Optional) ---${NC}"
  echo ""
  info "Captures errors, corrections, and lessons learned automatically."
  info "Enables your agent to learn from mistakes and get better over time."
  echo ""
  ask "Install Self-Improving Agent? [Y/n]"
  read -r INSTALL_SELFIMPROVE
  INSTALL_SELFIMPROVE="${INSTALL_SELFIMPROVE:-Y}"

  if [[ ! "$INSTALL_SELFIMPROVE" =~ ^[Yy] ]]; then
    info "Skipping Self-Improving Agent."
    return
  fi

  if npx --yes clawhub@latest --workdir "$OPENCLAW_DIR/workspace" install self-improving; then
    success "Self-Improving Agent skill installed"
  else
    warn "Could not install. Install manually: clawhub install self-improving"
  fi
}

# ============================================================
# Install Find Skills — Skill Discovery Helper
# ============================================================

install_find_skills() {
  echo ""
  echo -e "${BOLD}--- Find Skills — Skill Discovery (Optional) ---${NC}"
  echo ""
  info "Helps your agent discover and install new skills on-the-fly."
  info "When you ask 'how do I do X?', the agent can search ClawHub for matching skills."
  echo ""
  ask "Install Find Skills? [Y/n]"
  read -r INSTALL_FINDSKILLS
  INSTALL_FINDSKILLS="${INSTALL_FINDSKILLS:-Y}"

  if [[ ! "$INSTALL_FINDSKILLS" =~ ^[Yy] ]]; then
    info "Skipping Find Skills."
    return
  fi

  if npx --yes clawhub@latest --workdir "$OPENCLAW_DIR/workspace" install find-skills; then
    success "Find Skills installed"
  else
    warn "Could not install. Install manually: clawhub install find-skills"
  fi
}

# ============================================================
# Install Marketing Skills — Marketing Reference Library
# ============================================================

install_marketing_skills() {
  echo ""
  echo -e "${BOLD}--- Marketing Skills — Marketing Toolkit (Optional) ---${NC}"
  echo ""
  info "15+ marketing reference skills covering copywriting, CRO, SEO,"
  info "email sequences, A/B testing, pricing strategy, and more."
  echo ""
  ask "Install Marketing Skills? [Y/n]"
  read -r INSTALL_MARKETING
  INSTALL_MARKETING="${INSTALL_MARKETING:-Y}"

  if [[ ! "$INSTALL_MARKETING" =~ ^[Yy] ]]; then
    info "Skipping Marketing Skills."
    return
  fi

  if npx --yes clawhub@latest --workdir "$OPENCLAW_DIR/workspace" install marketing-skills; then
    success "Marketing Skills installed"
  else
    warn "Could not install. Install manually: clawhub install marketing-skills"
  fi
}

# ============================================================
# Install Healthcheck — Host Security Hardening
# ============================================================

install_healthcheck() {
  echo ""
  echo -e "${BOLD}--- Healthcheck — Security Hardening (Optional) ---${NC}"
  echo ""
  info "Audits host security: firewall, SSH, updates, exposure."
  info "Periodic security scans via heartbeat or cron scheduling."
  echo ""
  ask "Install Healthcheck? [Y/n]"
  read -r INSTALL_HEALTHCHECK
  INSTALL_HEALTHCHECK="${INSTALL_HEALTHCHECK:-Y}"

  if [[ ! "$INSTALL_HEALTHCHECK" =~ ^[Yy] ]]; then
    info "Skipping Healthcheck."
    return
  fi

  # Healthcheck is a built-in skill, just verify it's available
  HEALTHCHECK_PATH="$(npm root -g)/openclaw/skills/healthcheck"
  if [ -d "$HEALTHCHECK_PATH" ]; then
    success "Healthcheck skill available (built-in with OpenClaw)"
  else
    warn "Healthcheck skill not found at expected path."
    info "It should be included with OpenClaw. Try: openclaw --version"
  fi
}

# ============================================================
# Install Playwright MCP — Browser Automation
# ============================================================

install_playwright() {
  echo ""
  echo -e "${BOLD}--- Playwright — Browser Automation (Optional) ---${NC}"
  echo ""
  info "Navigate websites, click elements, fill forms, take screenshots."
  info "Full browser automation for complex web workflows."
  echo ""
  ask "Install Playwright MCP? [Y/n]"
  read -r INSTALL_PLAYWRIGHT
  INSTALL_PLAYWRIGHT="${INSTALL_PLAYWRIGHT:-Y}"

  if [[ ! "$INSTALL_PLAYWRIGHT" =~ ^[Yy] ]]; then
    info "Skipping Playwright."
    return
  fi

  if npx --yes clawhub@latest --workdir "$OPENCLAW_DIR/workspace" install playwright-mcp; then
    success "Playwright MCP skill installed"
  else
    warn "clawhub install failed. Install manually: clawhub install playwright-mcp"
  fi
}

# ============================================================
# Helper: Register MCP server in mcporter config
# ============================================================

register_mcp() {
  local name="$1"
  local command="$2"
  local MCPORTER_CONFIG="$OPENCLAW_DIR/workspace/config/mcporter.json"
  mkdir -p "$(dirname "$MCPORTER_CONFIG")"

  # Create config if it doesn't exist
  if [ ! -f "$MCPORTER_CONFIG" ]; then
    echo '{"mcpServers":{},"imports":[]}' > "$MCPORTER_CONFIG"
  fi

  # Add the MCP server entry (safe: uses env vars, not interpolated strings)
  MCP_NAME="$name" MCP_COMMAND="$command" MCP_CONFIG_PATH="$MCPORTER_CONFIG" \
  python3 -c '
import json, os
config_path = os.environ["MCP_CONFIG_PATH"]
name = os.environ["MCP_NAME"]
command = os.environ["MCP_COMMAND"]
with open(config_path) as f:
    config = json.load(f)
config.setdefault("mcpServers", {})[name] = {"command": command}
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
' 2>/dev/null && success "$name registered in mcporter config" \
  || warn "Could not register $name in mcporter — add manually"

  # Also register for specialist agent workspaces
  for ws in "$OPENCLAW_DIR"/workspace-*/config; do
    if [ -d "$(dirname "$ws")" ]; then
      mkdir -p "$ws"
      local AGENT_MCP="$ws/mcporter.json"
      if [ ! -f "$AGENT_MCP" ]; then
        echo '{"mcpServers":{},"imports":[]}' > "$AGENT_MCP"
      fi
      MCP_NAME="$name" MCP_COMMAND="$command" MCP_CONFIG_PATH="$AGENT_MCP" \
      python3 -c '
import json, os
config_path = os.environ["MCP_CONFIG_PATH"]
name = os.environ["MCP_NAME"]
command = os.environ["MCP_COMMAND"]
with open(config_path) as f:
    config = json.load(f)
config.setdefault("mcpServers", {})[name] = {"command": command}
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
' 2>/dev/null
    fi
  done
}

# ============================================================
# Summary
# ============================================================

show_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}✅ Clawdboss Setup Complete!${NC}                ${GREEN}║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  # ---- Agent Overview ----
  echo -e "  ${BOLD}Agent:${NC}     $AGENT_NAME $AGENT_EMOJI"
  echo -e "  ${BOLD}Tier:${NC}      $([ "$TIER_CHOICE" = "1" ] && echo "Solo" || ([ "$TIER_CHOICE" = "2" ] && echo "Team" || echo "Squad"))"
  echo -e "  ${BOLD}Provider:${NC}  $LLM_PROVIDER"
  echo -e "  ${BOLD}Config:${NC}    $CONFIG_FILE"
  echo -e "  ${BOLD}Secrets:${NC}   $ENV_FILE"
  echo -e "  ${BOLD}Workspace:${NC} $OPENCLAW_DIR/workspace"
  echo ""

  # ---- Agents ----
  if [ "$DEPLOY_COMMS" = true ] || [ "$DEPLOY_RESEARCH" = true ] || [ "$DEPLOY_SECURITY" = true ]; then
    echo -e "  ${BOLD}Agents:${NC}"
    echo "    • $AGENT_NAME $AGENT_EMOJI (main agent)"
    if [ "$DEPLOY_COMMS" = true ]; then
      echo "    • $COMMS_NAME 📡 (communications)"
    fi
    if [ "$DEPLOY_RESEARCH" = true ]; then
      echo "    • $RESEARCH_NAME 🔍 (search & discovery)"
    fi
    if [ "$DEPLOY_SECURITY" = true ]; then
      echo "    • $SECURITY_NAME 🛡️ (security)"
    fi
    echo ""
  fi

  # ---- Interface ----
  echo -e "  ${BOLD}Interface:${NC}"
  if [ "$USE_DISCORD" = true ]; then
    echo "    • Discord bot — connected to your server"
  fi
  if [ "$USE_CONSOLE" = true ]; then
    echo "    • ClawSuite Console — web dashboard at ~/clawsuite"
    if [ "${CONSOLE_SECURITY:-1}" = "2" ] && [ -n "${CONSOLE_DOMAIN:-}" ]; then
      echo "      URL: https://$CONSOLE_DOMAIN"
      echo "      Auth: $CONSOLE_AUTH_USER / [your password]"
      echo "      SSL: Caddy reverse proxy with auto-HTTPS"
    elif [ "${CONSOLE_SECURITY:-1}" = "3" ]; then
      echo "      URL: http://YOUR-SERVER-IP:3000 (no SSL)"
    else
      echo "      Access: SSH tunnel → http://localhost:3000"
    fi
  fi
  echo "    • OpenClaw TUI — terminal interface: openclaw tui"
  echo ""

  # ---- Ecosystem Tools ----
  echo -e "  ${BOLD}Ecosystem Tools:${NC}"
  if [[ "${INSTALL_CLAWMETRY:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Clawmetry — observability dashboard (localhost:8900)"
  fi
  if [[ "${INSTALL_CLAWSEC:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ ClawSec — Soul Guardian + advisory feed"
  fi
  if [[ "${INSTALL_OCTAVE:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Octave — structured agent memory"
  fi
  if [[ "${INSTALL_GRAPHTHULHU:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Graphthulhu — knowledge graph (Obsidian vault: $OPENCLAW_DIR/vault)"
  fi
  if [[ "${INSTALL_APITAP:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ ApiTap — API traffic interception"
  fi
  if [[ "${INSTALL_SCRAPLING:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Scrapling — web scraping (anti-bot bypass)"
  fi
  if [[ "${INSTALL_PLAYWRIGHT:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Playwright — browser automation"
  fi
  echo ""

  # ---- Skills ----
  echo -e "  ${BOLD}Skills Installed:${NC}"
  if [[ "${INSTALL_GITHUB:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ GitHub — issues, PRs, CI via gh CLI"
  fi
  if [[ "${INSTALL_HUMANIZER:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Humanizer — content humanization"
  fi
  if [[ "${INSTALL_SELFIMPROVE:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Self-Improving Agent — continuous learning"
  fi
  if [[ "${INSTALL_FINDSKILLS:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Find Skills — skill discovery helper"
  fi
  if [[ "${INSTALL_MARKETING:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Marketing Skills — CRO, SEO, copywriting, ads"
  fi
  if [[ "${INSTALL_HEALTHCHECK:-N}" =~ ^[Yy] ]]; then
    echo "    ✅ Healthcheck — host security auditing"
  fi
  echo "    ✅ Built-in skill dependencies pre-installed (see above)"
  echo ""

  # ---- Security ----
  echo -e "  ${BOLD}Security:${NC}"
  echo "    • API keys stored in $ENV_FILE (600 permissions)"
  echo "    • Config uses \${VAR} references — no plaintext keys"
  echo "    • All agents have prompt injection defense pre-configured"
  echo "    • Anti-loop rules prevent token-burning attacks"
  echo "    • External content treated as untrusted data"
  if [[ "${INSTALL_CLAWSEC:-N}" =~ ^[Yy] ]]; then
    echo "    • Soul Guardian — file integrity monitoring"
    echo "    • ClawSec advisory feed — vulnerability alerts"
  fi
  # Show hardening results if run
  if command -v ufw &>/dev/null; then
    local UFW_NOW
    UFW_NOW=$(ufw status 2>/dev/null | head -1)
    if [[ "$UFW_NOW" == *"active"* ]]; then
      echo "    • UFW firewall — enabled (SSH allowed)"
    fi
  fi
  local SSHD_ROOT
  SSHD_ROOT=$(grep -E "^\s*PermitRootLogin\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
  if [ "$SSHD_ROOT" = "prohibit-password" ] || [ "$SSHD_ROOT" = "no" ]; then
    echo "    • SSH root login — hardened ($SSHD_ROOT)"
  fi
  echo ""

  # ---- Next Steps (LAST) ----
  echo -e "  ${BOLD}Next Steps:${NC}"
  echo ""

  local STEP=1

  # Provider auth step (if needed)
  if [ "$LLM_PROVIDER" = "copilot" ]; then
    echo "    $STEP. Start the GitHub Copilot proxy (must run before OpenClaw):"
    echo ""
    echo "       npx copilot-api start --port 4141"
    echo ""
    echo "       On first run it will show a device auth URL + code."
    echo "       Open the URL in your browser, enter the code, and authorize"
    echo "       with a GitHub account that has a Copilot subscription."
    echo ""
    echo "       To run in the background:"
    echo "       tmux new-session -d -s copilot 'npx copilot-api start --port 4141'"
    echo ""
    STEP=$((STEP + 1))
  elif [ "$LLM_PROVIDER" = "openai-codex-oauth" ] && [ -z "${OAUTH_DEFERRED:-}" ]; then
    echo "    $STEP. Authenticate with OpenAI Codex (if not done during setup):"
    echo "       openclaw models auth login --provider openai-codex --set-default"
    echo ""
    STEP=$((STEP + 1))
  elif [ "$LLM_PROVIDER" = "gemini-cli-oauth" ] && [ -z "${OAUTH_DEFERRED:-}" ]; then
    echo "    $STEP. Authenticate with Gemini CLI (if not done during setup):"
    echo "       openclaw plugins enable google-gemini-cli-auth"
    echo "       openclaw models auth login --provider google-gemini-cli --set-default"
    echo ""
    STEP=$((STEP + 1))
  elif [ "$LLM_PROVIDER" = "anthropic-oauth" ] && [ -z "${OAUTH_DEFERRED:-}" ]; then
    echo "    $STEP. Authenticate with Anthropic (if not done during setup):"
    echo "       openclaw models auth paste-token --provider anthropic"
    echo ""
    STEP=$((STEP + 1))
  fi

  # Start OpenClaw
  echo "    $STEP. Start OpenClaw:"
  echo ""
  if [ "$(id -u)" = "0" ]; then
    echo "       tmux new-session -d -s openclaw 'openclaw gateway run'"
    echo ""
    echo "       (Running as root — use tmux instead of 'gateway start')"
    echo "       To attach: tmux attach -t openclaw"
    echo "       To detach: Ctrl+B then D"
  else
    echo "       openclaw gateway start"
    echo ""
    echo "       Or run in the background with tmux:"
    echo "       tmux new-session -d -s openclaw 'openclaw gateway run'"
  fi
  echo ""
  STEP=$((STEP + 1))

  # Check status
  echo "    $STEP. Check status:"
  echo "       openclaw status"
  echo ""
  STEP=$((STEP + 1))

  # Start ClawSuite Console
  if [ "$USE_CONSOLE" = true ]; then
    echo "    $STEP. Start ClawSuite Console (web dashboard):"
    echo ""
    if [ "${CONSOLE_SECURITY:-1}" = "2" ] && [ -n "${CONSOLE_DOMAIN:-}" ]; then
      echo "       cd ~/clawsuite && HOST=127.0.0.1 PORT=3000 node server-entry.js"
      echo ""
      echo "       Or in the background:"
      echo "       tmux new-session -d -s console 'cd ~/clawsuite && HOST=127.0.0.1 PORT=3000 node server-entry.js'"
      echo ""
      echo "       Access: https://$CONSOLE_DOMAIN"
      echo "       Auth:   $CONSOLE_AUTH_USER / [your password]"
      echo "       SSL:    Managed by Caddy (auto-renewed)"
    elif [ "${CONSOLE_SECURITY:-1}" = "3" ]; then
      echo "       cd ~/clawsuite && HOST=0.0.0.0 PORT=3000 node server-entry.js"
      echo ""
      echo "       Or in the background:"
      echo "       tmux new-session -d -s console 'cd ~/clawsuite && HOST=0.0.0.0 PORT=3000 node server-entry.js'"
      echo ""
      echo "       Access: http://YOUR-SERVER-IP:3000"
    else
      echo "       cd ~/clawsuite && HOST=127.0.0.1 PORT=3000 node server-entry.js"
      echo ""
      echo "       Or in the background:"
      echo "       tmux new-session -d -s console 'cd ~/clawsuite && HOST=127.0.0.1 PORT=3000 node server-entry.js'"
      echo ""
      echo "       Access via SSH tunnel:"
      echo "         ssh -L 3000:localhost:3000 user@your-server-ip"
      echo "         Then open: http://localhost:3000"
    fi
    echo ""
    STEP=$((STEP + 1))
  fi

  # Use your agent
  echo "    $STEP. Start chatting with your agent:"
  echo ""
  if [ "$USE_DISCORD" = true ]; then
    echo "       • Discord: Open your server and chat in the agent channel"
  fi
  if [ "$USE_CONSOLE" = true ]; then
    if [ "${CONSOLE_SECURITY:-1}" = "2" ] && [ -n "${CONSOLE_DOMAIN:-}" ]; then
      echo "       • Web: https://$CONSOLE_DOMAIN"
    else
      echo "       • Web: ClawSuite Console (see step above)"
    fi
  fi
  echo "       • Terminal: openclaw tui"
  echo ""
}

# ============================================================
# Main
# ============================================================

main() {
  banner

  # Check for existing config
  if [ -f "$CONFIG_FILE" ]; then
    warn "Existing config found at $CONFIG_FILE"
    ask "Overwrite? This will backup the current config [y/N]"
    read -r OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[Yy] ]]; then
      info "Aborting. Your existing config is untouched."
      exit 0
    fi
    # Use mktemp for unpredictable backup filename; verify no symlink before copy
    BACKUP=$(mktemp "${CONFIG_FILE}.bak.XXXXXX")
    if [ -L "$BACKUP" ]; then
      error "Symlink detected at backup path — aborting for safety"
      rm -f "$BACKUP"
      exit 1
    fi
    cp "$CONFIG_FILE" "$BACKUP"
    success "Backup created at $BACKUP"
    echo ""
  fi

  preflight
  collect_user_info
  collect_agent_info
  collect_keys
  generate_env
  generate_config
  deploy_workspaces

  # ---- Optional Tools & Skills ----
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}Optional Tools & Integrations${NC}               ${GREEN}║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  info "The following are all optional. Press Enter to accept defaults."
  echo ""

  install_octave
  install_graphthulhu
  install_apitap
  install_scrapling
  install_github_skill
  install_playwright
  install_humanizer
  install_self_improving
  install_find_skills
  install_marketing_skills
  install_healthcheck

  # Install ClawSuite Console (if selected)
  if [ "$USE_CONSOLE" = true ]; then
    echo ""
    echo -e "${BOLD}--- ClawSuite Console ---${NC}"
    echo ""
    info "Installing ClawSuite Console web dashboard..."

    CONSOLE_DIR="$HOME/clawsuite"
    if [ -d "$CONSOLE_DIR" ]; then
      info "Existing installation found at $CONSOLE_DIR — pulling latest..."
      (cd "$CONSOLE_DIR" && git pull --ff-only 2>/dev/null) || warn "Could not update — using existing version"
    else
      if git clone --depth 1 https://github.com/outsourc-e/clawsuite.git "$CONSOLE_DIR" 2>/dev/null; then
        success "ClawSuite Console cloned to $CONSOLE_DIR"
      else
        warn "Could not clone ClawSuite Console. Install manually:"
        warn "  git clone https://github.com/outsourc-e/clawsuite.git"
        USE_CONSOLE=false
      fi
    fi

    if [ "$USE_CONSOLE" = true ] && [ -d "$CONSOLE_DIR" ]; then
      (cd "$CONSOLE_DIR" && npm install --silent 2>&1 | tail -3) \
        && success "Dependencies installed" \
        || warn "npm install failed — run manually in $CONSOLE_DIR"

      # Create .env for ClawSuite Console
      CONSOLE_ENV="$CONSOLE_DIR/.env"
      cat > "$CONSOLE_ENV" << CONSOLEEOF
CLAWDBOT_GATEWAY_URL=ws://127.0.0.1:18789
CLAWDBOT_GATEWAY_TOKEN=${GATEWAY_TOKEN}
CONSOLEEOF
      chmod 600 "$CONSOLE_ENV"

      # Build for production
      info "Building ClawSuite Console..."
      (cd "$CONSOLE_DIR" && npm run build 2>&1 | tail -3) \
        && success "ClawSuite Console built successfully" \
        || warn "Build failed — run 'npm run build' manually in $CONSOLE_DIR"

      # SSL + Security setup for ClawSuite Console
      echo ""
      echo -e "${BOLD}ClawSuite Console Security:${NC}"
      echo ""
      echo "  1) Localhost only (access via SSH tunnel — most secure)"
      echo "  2) SSL with Caddy reverse proxy + basic auth (public HTTPS)"
      echo "  3) No security (HTTP on all interfaces — dev only)"
      echo ""
      ask "Choose security mode [1/2/3] (default: 1)"
      read -r CONSOLE_SECURITY
      CONSOLE_SECURITY="${CONSOLE_SECURITY:-1}"

      case "$CONSOLE_SECURITY" in
        2)
          # SSL with Caddy + basic auth
          info "Setting up Caddy reverse proxy with SSL..."

          # Install Caddy
          if ! command -v caddy &>/dev/null; then
            info "Installing Caddy web server..."
            local CADDY_INSTALLED=false

            if command -v apt-get &>/dev/null; then
              # Method 1: Official apt repo
              apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg 2>/dev/null

              # Remove stale/expired keyring before re-downloading
              rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null

              if curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                  | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null \
                && chmod a+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
                && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                  | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null \
                && apt-get update -qq 2>/dev/null \
                && apt-get install caddy -y -qq 2>/dev/null; then
                success "Caddy installed via apt"
                CADDY_INSTALLED=true
              else
                warn "Caddy apt repo failed. Trying static binary fallback..."
                # Clean up failed apt repo to avoid future update errors
                rm -f /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null
              fi
            fi

            # Method 2: Static binary from GitHub releases
            if [ "$CADDY_INSTALLED" = false ]; then
              local CADDY_ARCH="amd64"
              [ "$(uname -m)" = "aarch64" ] && CADDY_ARCH="arm64"
              local CADDY_TAG
              CADDY_TAG=$(curl -sS "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null \
                | grep -oP '"tag_name":\s*"\K[^"]+')

              if [ -n "$CADDY_TAG" ]; then
                local CADDY_VER="${CADDY_TAG#v}"
                local CADDY_URL="https://github.com/caddyserver/caddy/releases/download/${CADDY_TAG}/caddy_${CADDY_VER}_linux_${CADDY_ARCH}.tar.gz"
                if curl -fsSL -o /tmp/caddy.tar.gz "$CADDY_URL" 2>/dev/null; then
                  tar xzf /tmp/caddy.tar.gz -C /tmp caddy 2>/dev/null
                  if [ -f /tmp/caddy ]; then
                    mv /tmp/caddy /usr/local/bin/caddy && chmod +x /usr/local/bin/caddy
                    rm -f /tmp/caddy.tar.gz

                    # Create Caddy config dir if it doesn't exist
                    mkdir -p /etc/caddy

                    # Set up Caddy as a systemd service
                    if [ -d /etc/systemd/system ] && [ ! -f /etc/systemd/system/caddy.service ]; then
                      cat > /etc/systemd/system/caddy.service << 'CADDYSVC'
[Unit]
Description=Caddy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --resume
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
CADDYSVC
                      systemctl daemon-reload 2>/dev/null
                    fi

                    success "Caddy ${CADDY_VER} installed from GitHub release"
                    CADDY_INSTALLED=true
                  fi
                fi
                rm -f /tmp/caddy.tar.gz 2>/dev/null
              fi
            fi

            if [ "$CADDY_INSTALLED" = false ]; then
              warn "Could not install Caddy. Install manually: https://caddyserver.com/docs/install"
            fi
          fi

          if command -v caddy &>/dev/null; then
            info "SSL requires a domain name pointed at this server's IP."
            info "If you don't have a domain, press Enter to skip (IP-only, no SSL)."
            ask "Domain name for SSL (leave blank to skip)"
            read -r CONSOLE_DOMAIN

            if [ -z "$CONSOLE_DOMAIN" ]; then
              info "Skipping SSL. Console will listen on this server's IP without HTTPS."
              info "Access via: http://<your-server-ip>:3000"
              CONSOLE_HOST="0.0.0.0"
            else

            ask "Basic auth username (default: admin)"
            read -r CONSOLE_AUTH_USER
            CONSOLE_AUTH_USER="${CONSOLE_AUTH_USER:-admin}"

            while true; do
              ask "Basic auth password"
              read -rs CONSOLE_AUTH_PASS
              echo ""

              if [ -z "$CONSOLE_AUTH_PASS" ]; then
                warn "Password cannot be empty. Try again."
                continue
              fi

              ask "Confirm password"
              read -rs CONSOLE_AUTH_PASS_CONFIRM
              echo ""

              if [ "$CONSOLE_AUTH_PASS" != "$CONSOLE_AUTH_PASS_CONFIRM" ]; then
                warn "Passwords don't match. Try again."
              else
                break
              fi
            done

            # Hash the password for Caddy
            CONSOLE_AUTH_HASH=$(caddy hash-password --plaintext "$CONSOLE_AUTH_PASS" 2>/dev/null)

            if [ -n "$CONSOLE_AUTH_HASH" ] && [ -n "$CONSOLE_DOMAIN" ]; then
              # Write Caddyfile
              cat > /etc/caddy/Caddyfile << CADDYEOF
${CONSOLE_DOMAIN} {
    basicauth {
        ${CONSOLE_AUTH_USER} ${CONSOLE_AUTH_HASH}
    }
    reverse_proxy 127.0.0.1:3000
}
CADDYEOF

              # Restart Caddy
              systemctl restart caddy 2>/dev/null \
                || caddy start --config /etc/caddy/Caddyfile 2>/dev/null

              success "Caddy configured: https://$CONSOLE_DOMAIN → ClawSuite Console"
              info "Make sure your DNS A record points $CONSOLE_DOMAIN to this server's IP"
              info "Auth: $CONSOLE_AUTH_USER / [your password]"

              # Console should only listen on localhost now
              CONSOLE_HOST="127.0.0.1"
            else
              warn "Could not configure Caddy. Set up manually."
              CONSOLE_HOST="0.0.0.0"
            fi
            fi
          else
            warn "Caddy not available. Falling back to localhost-only mode."
            CONSOLE_HOST="127.0.0.1"
          fi
          ;;
        3)
          warn "Running without security — HTTP on all interfaces. Not recommended for production!"
          CONSOLE_HOST="0.0.0.0"
          ;;
        *)
          # Default: localhost only
          CONSOLE_HOST="127.0.0.1"
          info "Console will only be accessible via localhost (SSH tunnel recommended)"
          info "Connect via: ssh -L 3000:localhost:3000 user@your-server-ip"
          info "Then open: http://localhost:3000"
          ;;
      esac

      success "ClawSuite Console ready at $CONSOLE_DIR"
      if [ "$CONSOLE_HOST" = "127.0.0.1" ] && [ "$CONSOLE_SECURITY" != "2" ]; then
        info "Start with: cd $CONSOLE_DIR && HOST=127.0.0.1 PORT=3000 node server-entry.js"
        info "Access via SSH tunnel: ssh -L 3000:localhost:3000 user@server-ip"
      elif [ "${CONSOLE_DOMAIN:-}" ]; then
        info "Start with: cd $CONSOLE_DIR && HOST=127.0.0.1 PORT=3000 node server-entry.js"
        info "Access at: https://$CONSOLE_DOMAIN"
      else
        info "Start with: cd $CONSOLE_DIR && HOST=$CONSOLE_HOST PORT=3000 node server-entry.js"
      fi
    fi
  fi
  echo ""

  # Offer Clawmetry install
  echo -e "${BOLD}--- Observability (Optional) ---${NC}"
  echo ""
  info "Clawmetry is a free observability dashboard for OpenClaw agents."
  info "Shows token costs, sessions, crons, live message flow. Zero config."
  echo ""
  ask "Install Clawmetry? [Y/n]"
  read -r INSTALL_CLAWMETRY
  INSTALL_CLAWMETRY="${INSTALL_CLAWMETRY:-Y}"

  if [[ "$INSTALL_CLAWMETRY" =~ ^[Yy] ]]; then
    if command -v pip &>/dev/null || command -v pip3 &>/dev/null; then
      PIP_CMD="$(command -v pip3 || command -v pip)"
      "$PIP_CMD" install --break-system-packages --ignore-installed clawmetry 2>/dev/null \
        || "$PIP_CMD" install --break-system-packages clawmetry 2>/dev/null \
        || "$PIP_CMD" install --user clawmetry 2>/dev/null \
        || warn "Could not install clawmetry via pip. Install manually: pip install clawmetry"
      command -v clawmetry &>/dev/null && success "Clawmetry installed. Run: clawmetry" \
        || info "Clawmetry installed. Run: python3 -m clawmetry"
    else
      warn "pip not found. Install clawmetry manually: pip install clawmetry"
    fi
  fi

  # Offer ClawSec install
  echo ""
  echo -e "${BOLD}--- Security Suite (Optional) ---${NC}"
  echo ""
  info "ClawSec provides file integrity protection (Soul Guardian),"
  info "advisory feed monitoring, and malicious skill detection."
  echo ""
  ask "Install ClawSec security suite? [Y/n]"
  read -r INSTALL_CLAWSEC
  INSTALL_CLAWSEC="${INSTALL_CLAWSEC:-Y}"

  if [[ "$INSTALL_CLAWSEC" =~ ^[Yy] ]]; then
    CLAWSEC_TMP="$(mktemp -d)"
    if git clone --depth 1 https://github.com/prompt-security/clawsec.git "$CLAWSEC_TMP" 2>/dev/null; then
      SKILLS_DIR="$OPENCLAW_DIR/skills"
      mkdir -p "$SKILLS_DIR"
      cp -r "$CLAWSEC_TMP/skills/clawsec-suite" "$SKILLS_DIR/" 2>/dev/null
      cp -r "$CLAWSEC_TMP/skills/soul-guardian" "$SKILLS_DIR/" 2>/dev/null
      cp -r "$CLAWSEC_TMP/skills/clawsec-feed" "$SKILLS_DIR/" 2>/dev/null
      rm -rf "$CLAWSEC_TMP"

      # Initialize soul-guardian baselines
      if [ -f "$SKILLS_DIR/soul-guardian/scripts/soul_guardian.py" ]; then
        python3 "$SKILLS_DIR/soul-guardian/scripts/soul_guardian.py" init \
          --actor setup --note "initial baseline" 2>/dev/null \
          && success "Soul Guardian baselines initialized" \
          || warn "Soul Guardian init failed — run manually after setup"
      fi

      success "ClawSec suite installed to $SKILLS_DIR"
    else
      warn "Could not clone ClawSec. Install manually: git clone https://github.com/prompt-security/clawsec.git"
    fi
  fi

  # ---- Memory Hybrid Plugin ----
  echo ""
  echo -e "${BOLD}--- Memory Hybrid Plugin ---${NC}"
  echo ""
  info "Installing memory-hybrid plugin (SQLite + LanceDB two-tier memory)..."
  info "This gives your agent structured fact storage + semantic vector search."
  echo ""

  local EXTENSIONS_DIR
  EXTENSIONS_DIR="$(npm root -g)/openclaw/extensions/memory-hybrid"

  if [ -d "$EXTENSIONS_DIR" ] && [ -f "$EXTENSIONS_DIR/index.ts" ]; then
    info "memory-hybrid already installed at $EXTENSIONS_DIR"
  else
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local BUNDLED="$SCRIPT_DIR/extensions/memory-hybrid"

    if [ -d "$BUNDLED" ] && [ -f "$BUNDLED/index.ts" ]; then
      mkdir -p "$EXTENSIONS_DIR"
      cp "$BUNDLED"/{package.json,openclaw.plugin.json,config.ts,index.ts} "$EXTENSIONS_DIR/"
      success "memory-hybrid plugin files copied to $EXTENSIONS_DIR"
    else
      warn "Bundled memory-hybrid files not found. Plugin may not work."
    fi
  fi

  # Install dependencies
  if [ -d "$EXTENSIONS_DIR" ]; then
    info "Installing memory-hybrid npm dependencies..."
    (cd "$EXTENSIONS_DIR" && npm install --silent 2>&1 | tail -3) \
      && success "memory-hybrid dependencies installed" \
      || warn "npm install failed in $EXTENSIONS_DIR — run manually: cd $EXTENSIONS_DIR && npm install"

    # Also install better-sqlite3 in the OpenClaw state dir
    local OPENCLAW_STATE_DIR="$HOME/.openclaw"
    if [ ! -f "$OPENCLAW_STATE_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
      info "Installing better-sqlite3 in $OPENCLAW_STATE_DIR..."
      (cd "$OPENCLAW_STATE_DIR" && npm install better-sqlite3 --silent 2>&1 | tail -3) \
        && success "better-sqlite3 installed" \
        || warn "better-sqlite3 install failed — run: cd $OPENCLAW_STATE_DIR && npm install better-sqlite3"
    fi

    # Create memory directory
    mkdir -p "$OPENCLAW_STATE_DIR/memory"
    success "Memory directory ready: $OPENCLAW_STATE_DIR/memory"
  fi

  # ---- Built-in Skills Dependencies ----
  # Pre-install skill dependencies directly (no Homebrew needed on Linux)
  # This replaces `openclaw configure --section skills` which fails without brew
  install_skill_deps

  # ---- OAuth / Deferred Auth Login ----
  if [ -n "${OAUTH_DEFERRED:-}" ]; then
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}🔐 LLM Provider Authentication${NC}               ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    case "$OAUTH_DEFERRED" in
      openai-codex)
        info "Authenticating with OpenAI Codex OAuth..."
        info "This will open a browser for ChatGPT login."
        echo ""
        openclaw models auth login --provider openai-codex --set-default 2>&1 || {
          warn "OAuth login failed or was skipped."
          info "Run later: openclaw models auth login --provider openai-codex --set-default"
        }
        ;;
      google-gemini-cli)
        info "Enabling Gemini CLI auth plugin..."
        openclaw plugins enable google-gemini-cli-auth 2>/dev/null
        echo ""
        info "Authenticating with Google Gemini CLI OAuth..."
        info "This will open a browser for Google account login."
        echo ""
        openclaw models auth login --provider google-gemini-cli --set-default 2>&1 || {
          warn "OAuth login failed or was skipped."
          info "Run later:"
          info "  openclaw plugins enable google-gemini-cli-auth"
          info "  openclaw models auth login --provider google-gemini-cli --set-default"
        }
        ;;
      anthropic)
        info "Authenticating with Anthropic setup-token..."
        info "You'll need your Claude setup token from claude.ai/settings."
        echo ""
        openclaw models auth paste-token --provider anthropic 2>&1 || {
          warn "Token setup failed or was skipped."
          info "Run later: openclaw models auth paste-token --provider anthropic"
        }
        ;;
    esac
    echo ""
  fi

  # ---- Server Hardening ----
  harden_server

  # ---- Auto-start Gateway ----
  echo ""
  info "Starting OpenClaw gateway..."

  if [ "$(id -u)" = "0" ]; then
    # Running as root — use tmux (systemd services shouldn't run as root)
    if command -v tmux &>/dev/null; then
      # Kill any existing session first
      tmux kill-session -t openclaw 2>/dev/null || true
      tmux new-session -d -s openclaw "openclaw gateway run"
      sleep 2
      if tmux has-session -t openclaw 2>/dev/null; then
        success "Gateway started in tmux session 'openclaw'"
        info "Attach with: tmux attach -t openclaw"
        info "Detach with: Ctrl+B then D"
      else
        warn "Gateway may not have started. Check: tmux attach -t openclaw"
      fi
    else
      warn "tmux not found — start the gateway manually: openclaw gateway run"
    fi
  else
    # Non-root — try systemd service, fall back to tmux
    if [ -d /etc/systemd/system ] && command -v systemctl &>/dev/null; then
      # Create systemd service if it doesn't exist
      if [ ! -f /etc/systemd/system/openclaw.service ]; then
        info "Setting up OpenClaw as a systemd service..."
        local OPENCLAW_BIN
        OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || echo "/usr/local/bin/openclaw")"
        local CURRENT_USER
        CURRENT_USER="$(whoami)"

        sudo tee /etc/systemd/system/openclaw.service > /dev/null << SVCEOF
[Unit]
Description=OpenClaw AI Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$HOME
ExecStart=$OPENCLAW_BIN gateway run
Restart=on-failure
RestartSec=5
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
SVCEOF
        sudo systemctl daemon-reload 2>/dev/null
        sudo systemctl enable openclaw 2>/dev/null
        success "Systemd service created and enabled"
      fi

      sudo systemctl start openclaw 2>/dev/null
      sleep 2
      if systemctl is-active --quiet openclaw 2>/dev/null; then
        success "Gateway started via systemd"
        info "Check status: systemctl status openclaw"
        info "View logs: journalctl -u openclaw -f"
      else
        warn "Systemd start may have failed. Falling back to tmux..."
        if command -v tmux &>/dev/null; then
          tmux kill-session -t openclaw 2>/dev/null || true
          tmux new-session -d -s openclaw "openclaw gateway run"
          sleep 2
          if tmux has-session -t openclaw 2>/dev/null; then
            success "Gateway started in tmux session 'openclaw'"
          else
            warn "Could not start gateway. Run manually: openclaw gateway start"
          fi
        else
          openclaw gateway start 2>/dev/null &
          sleep 2
          success "Gateway start attempted in background"
        fi
      fi
    elif command -v tmux &>/dev/null; then
      tmux kill-session -t openclaw 2>/dev/null || true
      tmux new-session -d -s openclaw "openclaw gateway run"
      sleep 2
      if tmux has-session -t openclaw 2>/dev/null; then
        success "Gateway started in tmux session 'openclaw'"
        info "Attach with: tmux attach -t openclaw"
      else
        warn "Could not start gateway. Run manually: openclaw gateway start"
      fi
    else
      openclaw gateway start 2>/dev/null &
      sleep 2
      success "Gateway start attempted in background"
    fi
  fi

  show_summary
}

# ============================================================
# Install Skill Dependencies (replaces openclaw configure --section skills)
# Pre-installs binaries that OpenClaw skills need, without requiring Homebrew.
# ============================================================

install_skill_deps() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}Built-in Skills — Dependency Install${NC}        ${GREEN}║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  info "Installing dependencies for all OpenClaw built-in skills."
  info "macOS-only skills will be skipped automatically on Linux."
  echo ""

  local BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
  export PATH="$BIN_DIR:$HOME/.cargo/bin:$PATH"

  local INSTALLED=0
  local SKIPPED=0
  local FAILED=0

  # Helper: download a GitHub release binary tarball
  # Usage: gh_release_install <repo> <bin_name> [version]
  gh_release_install() {
    local REPO="$1"
    local BIN_NAME="$2"
    local VERSION="${3:-latest}"
    local ARCH="amd64"
    [ "$(uname -m)" = "aarch64" ] && ARCH="arm64"

    local TAG
    if [ "$VERSION" = "latest" ]; then
      TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+')
    else
      TAG="$VERSION"
    fi

    if [ -z "$TAG" ]; then
      return 1
    fi

    # Strip leading 'v' for filename patterns
    local VER="${TAG#v}"
    local BASE_NAME="${BIN_NAME}"

    # Try common naming patterns
    local URLS=(
      "https://github.com/$REPO/releases/download/$TAG/${BASE_NAME}_${VER}_linux_${ARCH}.tar.gz"
      "https://github.com/$REPO/releases/download/$TAG/${BASE_NAME}_linux_${ARCH}.tar.gz"
      "https://github.com/$REPO/releases/download/$TAG/${BASE_NAME}-linux-${ARCH}.tar.gz"
    )

    local TMPFILE="/tmp/${BIN_NAME}_release.tar.gz"
    for url in "${URLS[@]}"; do
      if curl -fsSL -o "$TMPFILE" "$url" 2>/dev/null; then
        (cd /tmp && tar xzf "$TMPFILE" "$BIN_NAME" 2>/dev/null || tar xzf "$TMPFILE" 2>/dev/null)
        if [ -f "/tmp/$BIN_NAME" ]; then
          mv "/tmp/$BIN_NAME" "$BIN_DIR/" && chmod +x "$BIN_DIR/$BIN_NAME"
          rm -f "$TMPFILE"
          return 0
        fi
      fi
    done
    rm -f "$TMPFILE"
    return 1
  }

  # ============================================================
  # System tools (via apt)
  # ============================================================

  echo -e "  ${BOLD}System packages:${NC}"

  # --- ffmpeg (video-frames skill) ---
  if ! command -v ffmpeg &>/dev/null; then
    info "Installing ffmpeg..."
    apt-get install -y -qq ffmpeg 2>/dev/null \
      && success "ffmpeg installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "ffmpeg install failed"; FAILED=$((FAILED + 1)); }
  else
    success "ffmpeg ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- tmux ---
  if ! command -v tmux &>/dev/null; then
    info "Installing tmux..."
    apt-get install -y -qq tmux 2>/dev/null \
      && success "tmux installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "tmux install failed"; FAILED=$((FAILED + 1)); }
  else
    success "tmux ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- jq (session-logs, trello) ---
  if ! command -v jq &>/dev/null; then
    info "Installing jq..."
    apt-get install -y -qq jq 2>/dev/null \
      && success "jq installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "jq install failed"; FAILED=$((FAILED + 1)); }
  else
    success "jq ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- ripgrep (session-logs) ---
  if ! command -v rg &>/dev/null; then
    info "Installing ripgrep..."
    apt-get install -y -qq ripgrep 2>/dev/null \
      && success "ripgrep installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "ripgrep install failed"; FAILED=$((FAILED + 1)); }
  else
    success "ripgrep ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # ============================================================
  # Python tools
  # ============================================================

  echo ""
  echo -e "  ${BOLD}Python tools:${NC}"

  # --- uv (Python package runner — needed by nano-banana-pro, nano-pdf) ---
  if ! command -v uv &>/dev/null; then
    info "Installing uv (Python package manager)..."
    if curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh 2>/dev/null; then
      export PATH="$HOME/.local/bin:$PATH"
      success "uv installed"
      INSTALLED=$((INSTALLED + 1))
    else
      warn "Could not install uv. Install manually: curl -LsSf https://astral.sh/uv/install.sh | sh"
      FAILED=$((FAILED + 1))
    fi
  else
    success "uv ✓ ($(uv --version 2>/dev/null))"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- nano-pdf (via uv) ---
  if ! command -v nano-pdf &>/dev/null; then
    if command -v uv &>/dev/null; then
      info "Installing nano-pdf..."
      uv tool install nano-pdf 2>/dev/null \
        && success "nano-pdf installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "nano-pdf install failed"; FAILED=$((FAILED + 1)); }
    else
      warn "Skipping nano-pdf (uv not available)"
      FAILED=$((FAILED + 1))
    fi
  else
    success "nano-pdf ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- openai-whisper (local speech-to-text) ---
  if ! command -v whisper &>/dev/null; then
    info "Installing openai-whisper (local STT)..."
    if command -v uv &>/dev/null; then
      uv tool install openai-whisper 2>/dev/null \
        && success "openai-whisper installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "openai-whisper install failed (may need PyTorch)"; FAILED=$((FAILED + 1)); }
    elif command -v pip3 &>/dev/null; then
      pip3 install --break-system-packages openai-whisper 2>/dev/null \
        && success "openai-whisper installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "openai-whisper install failed"; FAILED=$((FAILED + 1)); }
    else
      warn "Skipping openai-whisper (no uv or pip3)"
      FAILED=$((FAILED + 1))
    fi
  else
    success "openai-whisper ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # ============================================================
  # Node.js / npm tools
  # ============================================================

  echo ""
  echo -e "  ${BOLD}Node.js tools:${NC}"

  # --- clawhub (skill marketplace) ---
  if ! command -v clawhub &>/dev/null; then
    info "Installing clawhub..."
    npm install -g clawhub 2>/dev/null \
      && success "clawhub installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "clawhub install failed"; FAILED=$((FAILED + 1)); }
  else
    success "clawhub ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- mcporter (MCP server management) ---
  if ! command -v mcporter &>/dev/null; then
    info "Installing mcporter..."
    npm install -g mcporter 2>/dev/null \
      && success "mcporter installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "mcporter install failed"; FAILED=$((FAILED + 1)); }
  else
    success "mcporter ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- Gemini CLI (Google AI) ---
  if ! command -v gemini &>/dev/null; then
    info "Installing Gemini CLI..."
    npm install -g @google/gemini-cli 2>/dev/null \
      && success "Gemini CLI installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "Gemini CLI install failed"; FAILED=$((FAILED + 1)); }
  else
    success "Gemini CLI ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- oracle (web search/scrape CLI) ---
  if ! command -v oracle &>/dev/null; then
    info "Installing oracle..."
    npm install -g @steipete/oracle 2>/dev/null \
      && success "oracle installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "oracle install failed"; FAILED=$((FAILED + 1)); }
  else
    success "oracle ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- summarize (URL/file/YouTube summarizer) ---
  if ! command -v summarize &>/dev/null; then
    info "Installing summarize..."
    npm install -g @steipete/summarize 2>/dev/null \
      && success "summarize installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "summarize install failed"; FAILED=$((FAILED + 1)); }
  else
    success "summarize ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- obsidian-cli (vault management) ---
  if ! command -v obsidian-cli &>/dev/null; then
    info "Installing obsidian-cli..."
    npm install -g obsidian-cli 2>/dev/null \
      && success "obsidian-cli installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "obsidian-cli install failed"; FAILED=$((FAILED + 1)); }
  else
    success "obsidian-cli ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # ============================================================
  # GitHub CLI (special install — official apt repo)
  # ============================================================

  echo ""
  echo -e "  ${BOLD}GitHub CLI:${NC}"

  if ! command -v gh &>/dev/null; then
    info "Installing GitHub CLI (gh)..."
    if command -v apt-get &>/dev/null; then
      (type -p wget >/dev/null || apt-get install -y -qq wget) \
        && mkdir -p -m 755 /etc/apt/keyrings \
        && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null \
        && cat "$out" | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null \
        && apt-get update -qq && apt-get install gh -y -qq \
        && success "gh CLI installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "gh install failed — install manually: https://cli.github.com"; FAILED=$((FAILED + 1)); }
      rm -f "$out" 2>/dev/null
    else
      warn "Could not install gh CLI (no apt). Install manually: https://cli.github.com"
      FAILED=$((FAILED + 1))
    fi
  else
    success "gh CLI ✓ ($(gh --version 2>/dev/null | head -1))"
    SKIPPED=$((SKIPPED + 1))
  fi

  # ============================================================
  # 1Password CLI (official Linux install)
  # ============================================================

  echo ""
  echo -e "  ${BOLD}1Password CLI:${NC}"

  if ! command -v op &>/dev/null; then
    info "Installing 1Password CLI..."
    if command -v apt-get &>/dev/null; then
      # Clean up any stale 1Password GPG keys/repos first
      rm -f /usr/share/keyrings/1password-archive-keyring.gpg 2>/dev/null
      rm -f /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg 2>/dev/null
      rm -f /etc/apt/sources.list.d/1password.list 2>/dev/null

      curl -sS https://downloads.1password.com/linux/keys/1password.asc 2>/dev/null \
        | gpg --batch --yes --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg 2>/dev/null \
        && chmod a+r /usr/share/keyrings/1password-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
          | tee /etc/apt/sources.list.d/1password.list > /dev/null \
        && mkdir -p /etc/debsig/policies/AC2D62742012EA22/ \
        && curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
          | tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null \
        && mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 \
        && curl -sS https://downloads.1password.com/linux/keys/1password.asc \
          | gpg --batch --yes --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg 2>/dev/null \
        && chmod a+r /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg \
        && apt-get update -qq 2>/dev/null && apt-get install -y -qq 1password-cli \
        && success "1Password CLI installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "1Password CLI install failed"; FAILED=$((FAILED + 1));
             # Clean up failed repo so it doesn't break future apt operations
             rm -f /etc/apt/sources.list.d/1password.list 2>/dev/null; }
    else
      warn "Skipping 1Password CLI (no apt)"
      FAILED=$((FAILED + 1))
    fi
  else
    success "1Password CLI ✓ ($(op --version 2>/dev/null))"
    SKIPPED=$((SKIPPED + 1))
  fi

  # ============================================================
  # GitHub Release binaries (Go-based tools)
  # ============================================================

  echo ""
  echo -e "  ${BOLD}CLI tools (GitHub releases):${NC}"

  # --- sag (ElevenLabs TTS) ---
  if ! command -v sag &>/dev/null; then
    info "Installing sag (ElevenLabs TTS)..."
    gh_release_install "steipete/sag" "sag" \
      && success "sag installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "sag install failed — https://github.com/steipete/sag/releases"; FAILED=$((FAILED + 1)); }
  else
    success "sag ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- gog (Gmail/Calendar/Drive CLI) ---
  if ! command -v gog &>/dev/null && ! command -v gogcli &>/dev/null; then
    info "Installing gog (Google Workspace CLI)..."
    gh_release_install "steipete/gogcli" "gogcli" \
      && success "gog installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "gog install failed — try: go install github.com/steipete/gogcli@latest"; FAILED=$((FAILED + 1)); }
  else
    success "gog ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- goplaces (Google Places CLI) ---
  if ! command -v goplaces &>/dev/null; then
    info "Installing goplaces..."
    gh_release_install "steipete/goplaces" "goplaces" \
      && success "goplaces installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "goplaces install failed"; FAILED=$((FAILED + 1)); }
  else
    success "goplaces ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- camsnap (camera snapshot CLI) ---
  if ! command -v camsnap &>/dev/null; then
    info "Installing camsnap..."
    gh_release_install "steipete/camsnap" "camsnap" \
      && success "camsnap installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "camsnap install failed"; FAILED=$((FAILED + 1)); }
  else
    success "camsnap ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- openhue (Philips Hue CLI) ---
  if ! command -v openhue &>/dev/null; then
    info "Installing openhue..."
    local OPENHUE_ARCH="x86_64"
    [ "$(uname -m)" = "aarch64" ] && OPENHUE_ARCH="arm64"
    local OPENHUE_TAG
    OPENHUE_TAG=$(curl -s "https://api.github.com/repos/openhue/openhue-cli/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+')
    if [ -n "$OPENHUE_TAG" ]; then
      local OPENHUE_URL="https://github.com/openhue/openhue-cli/releases/download/$OPENHUE_TAG/openhue_Linux_${OPENHUE_ARCH}.tar.gz"
      if curl -fsSL -o /tmp/openhue.tar.gz "$OPENHUE_URL" 2>/dev/null; then
        (cd /tmp && tar xzf openhue.tar.gz openhue 2>/dev/null && mv openhue "$BIN_DIR/" && chmod +x "$BIN_DIR/openhue")
        rm -f /tmp/openhue.tar.gz
        success "openhue installed"
        INSTALLED=$((INSTALLED + 1))
      else
        warn "openhue download failed"
        FAILED=$((FAILED + 1))
      fi
    else
      warn "Could not determine openhue version"
      FAILED=$((FAILED + 1))
    fi
  else
    success "openhue ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- himalaya (IMAP email CLI) ---
  if ! command -v himalaya &>/dev/null; then
    info "Installing himalaya (email CLI)..."
    local HIMA_ARCH="x86_64"
    [ "$(uname -m)" = "aarch64" ] && HIMA_ARCH="aarch64"
    local HIMA_TAG
    HIMA_TAG=$(curl -s "https://api.github.com/repos/pimalaya/himalaya/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+')
    if [ -n "$HIMA_TAG" ]; then
      local HIMA_URL="https://github.com/pimalaya/himalaya/releases/download/$HIMA_TAG/himalaya.${HIMA_ARCH}-linux.tgz"
      if curl -fsSL -o /tmp/himalaya.tgz "$HIMA_URL" 2>/dev/null; then
        (cd /tmp && tar xzf himalaya.tgz && mv himalaya "$BIN_DIR/" && chmod +x "$BIN_DIR/himalaya")
        rm -f /tmp/himalaya.tgz
        success "himalaya installed"
        INSTALLED=$((INSTALLED + 1))
      else
        warn "himalaya download failed"
        FAILED=$((FAILED + 1))
      fi
    else
      warn "Could not determine himalaya version"
      FAILED=$((FAILED + 1))
    fi
  else
    success "himalaya ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # --- spogo (Spotify CLI) ---
  if ! command -v spogo &>/dev/null; then
    info "Installing spogo (Spotify CLI)..."
    gh_release_install "steipete/spogo" "spogo" \
      && success "spogo installed" && INSTALLED=$((INSTALLED + 1)) \
      || { warn "spogo install failed"; FAILED=$((FAILED + 1)); }
  else
    success "spogo ✓"
    SKIPPED=$((SKIPPED + 1))
  fi

  # ============================================================
  # Go-installable tools (require Go runtime)
  # ============================================================

  echo ""
  echo -e "  ${BOLD}Go-based tools:${NC}"

  if command -v go &>/dev/null; then
    # --- blogwatcher ---
    if ! command -v blogwatcher &>/dev/null; then
      info "Installing blogwatcher..."
      go install github.com/Hyaxia/blogwatcher/cmd/blogwatcher@latest 2>/dev/null \
        && success "blogwatcher installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "blogwatcher install failed"; FAILED=$((FAILED + 1)); }
    else
      success "blogwatcher ✓"
      SKIPPED=$((SKIPPED + 1))
    fi

    # --- blucli (Bluetooth CLI) ---
    if ! command -v blu &>/dev/null; then
      info "Installing blucli..."
      go install github.com/steipete/blucli/cmd/blu@latest 2>/dev/null \
        && success "blucli installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "blucli install failed"; FAILED=$((FAILED + 1)); }
    else
      success "blucli ✓"
      SKIPPED=$((SKIPPED + 1))
    fi

    # --- eightctl (8sleep CLI) ---
    if ! command -v eightctl &>/dev/null; then
      info "Installing eightctl..."
      go install github.com/steipete/eightctl/cmd/eightctl@latest 2>/dev/null \
        && success "eightctl installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "eightctl install failed"; FAILED=$((FAILED + 1)); }
    else
      success "eightctl ✓"
      SKIPPED=$((SKIPPED + 1))
    fi

    # --- gifgrep ---
    if ! command -v gifgrep &>/dev/null; then
      info "Installing gifgrep..."
      go install github.com/steipete/gifgrep/cmd/gifgrep@latest 2>/dev/null \
        && success "gifgrep installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "gifgrep install failed"; FAILED=$((FAILED + 1)); }
    else
      success "gifgrep ✓"
      SKIPPED=$((SKIPPED + 1))
    fi

    # --- ordercli (food ordering) ---
    if ! command -v ordercli &>/dev/null; then
      info "Installing ordercli..."
      go install github.com/steipete/ordercli/cmd/ordercli@latest 2>/dev/null \
        && success "ordercli installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "ordercli install failed"; FAILED=$((FAILED + 1)); }
    else
      success "ordercli ✓"
      SKIPPED=$((SKIPPED + 1))
    fi

    # --- wacli (WhatsApp CLI) ---
    if ! command -v wacli &>/dev/null; then
      info "Installing wacli..."
      go install github.com/steipete/wacli/cmd/wacli@latest 2>/dev/null \
        && success "wacli installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "wacli install failed"; FAILED=$((FAILED + 1)); }
    else
      success "wacli ✓"
      SKIPPED=$((SKIPPED + 1))
    fi

    # --- sonoscli (Sonos CLI) ---
    if ! command -v sonos &>/dev/null; then
      info "Installing sonoscli..."
      go install github.com/steipete/sonoscli/cmd/sonos@latest 2>/dev/null \
        && success "sonoscli installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "sonoscli install failed"; FAILED=$((FAILED + 1)); }
    else
      success "sonoscli ✓"
      SKIPPED=$((SKIPPED + 1))
    fi

    # --- songsee (audio spectrograms) ---
    if ! command -v songsee &>/dev/null; then
      info "Installing songsee..."
      go install github.com/steipete/songsee@latest 2>/dev/null \
        && success "songsee installed" && INSTALLED=$((INSTALLED + 1)) \
        || { warn "songsee install failed"; FAILED=$((FAILED + 1)); }
    else
      success "songsee ✓"
      SKIPPED=$((SKIPPED + 1))
    fi
  else
    info "Go not installed — skipping Go-based tools"
    info "(blogwatcher, blucli, eightctl, gifgrep, ordercli, wacli, sonoscli, songsee)"
    info "Install Go: https://go.dev/dl/ then re-run setup"
    SKIPPED=$((SKIPPED + 8))
  fi

  # ============================================================
  # macOS-only skills (skip on Linux)
  # ============================================================

  echo ""
  echo -e "  ${BOLD}Skipped (macOS-only):${NC}"
  info "apple-notes (memo), apple-reminders (remindctl), bear-notes (grizzly),"
  info "imsg, peekaboo, things-mac, model-usage (codexbar)"

  # ============================================================
  # Summary
  # ============================================================

  echo ""
  echo -e "  ${BOLD}────────────────────────────────${NC}"
  success "Skills dependencies: ${INSTALLED} installed, ${SKIPPED} already present, ${FAILED} failed"
  if [ "$FAILED" -gt 0 ]; then
    warn "Some installs failed. Run 'openclaw doctor' to check skill status."
  fi
  info "API keys can be configured later: openclaw configure --section skills"
  echo ""
}

# ============================================================
# Server Hardening (post-install)
# ============================================================

harden_server() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}🛡️  Server Hardening${NC}                        ${GREEN}║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  info "Recommended security hardening for VPS/server deployments."
  info "Skip if running locally (laptop/workstation) or inside a container."
  echo ""
  ask "Run server hardening? [Y/n]"
  read -r RUN_HARDENING
  RUN_HARDENING="${RUN_HARDENING:-Y}"

  if [[ ! "$RUN_HARDENING" =~ ^[Yy] ]]; then
    info "Skipped server hardening."
    return
  fi

  local CHANGES_MADE=false

  # --- 1. Firewall (UFW) ---
  echo ""
  echo -e "  ${BOLD}1. Firewall (UFW)${NC}"
  echo ""

  if command -v ufw &>/dev/null; then
    local UFW_STATUS
    UFW_STATUS=$(ufw status 2>/dev/null | head -1)
    if [[ "$UFW_STATUS" == *"inactive"* ]]; then
      warn "Firewall is INACTIVE — all ports are exposed to the internet."
      info "This will allow SSH (port 22) and block everything else from outside."
      ask "Enable UFW firewall? [Y/n]"
      read -r ENABLE_UFW
      ENABLE_UFW="${ENABLE_UFW:-Y}"
      if [[ "$ENABLE_UFW" =~ ^[Yy] ]]; then
        ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
        # If Caddy/SSL was configured, allow HTTPS too
        if [ "${CONSOLE_SECURITY:-1}" = "2" ] && [ -n "${CONSOLE_DOMAIN:-}" ]; then
          ufw allow 80/tcp comment "HTTP (Caddy redirect)" >/dev/null 2>&1
          ufw allow 443/tcp comment "HTTPS (Caddy)" >/dev/null 2>&1
          info "Allowed ports 80/443 for Caddy SSL"
        fi
        echo "y" | ufw enable >/dev/null 2>&1
        success "Firewall enabled (SSH allowed, rest blocked from outside)"
        CHANGES_MADE=true
      else
        warn "Skipped — firewall remains inactive"
      fi
    else
      success "Firewall already active"
    fi
  else
    info "Installing UFW..."
    if apt-get install -y -qq ufw 2>/dev/null; then
      ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
      if [ "${CONSOLE_SECURITY:-1}" = "2" ] && [ -n "${CONSOLE_DOMAIN:-}" ]; then
        ufw allow 80/tcp comment "HTTP (Caddy redirect)" >/dev/null 2>&1
        ufw allow 443/tcp comment "HTTPS (Caddy)" >/dev/null 2>&1
      fi
      echo "y" | ufw enable >/dev/null 2>&1
      success "UFW installed and enabled (SSH allowed)"
      CHANGES_MADE=true
    else
      warn "Could not install UFW. Install manually: apt-get install ufw"
    fi
  fi

  # --- 2. Block external access to copilot-api port 4141 ---
  if [ "$LLM_PROVIDER" = "copilot" ]; then
    echo ""
    echo -e "  ${BOLD}2. Copilot API Port Protection${NC}"
    echo ""
    info "copilot-api binds to 0.0.0.0:4141 by default (no --host flag)."
    info "This means it's accessible from the internet if firewall is off."

    if command -v ufw &>/dev/null; then
      # UFW handles this — port 4141 isn't in the allow list, so it's blocked
      local UFW_STATUS_NOW
      UFW_STATUS_NOW=$(ufw status 2>/dev/null | head -1)
      if [[ "$UFW_STATUS_NOW" == *"active"* ]]; then
        success "Port 4141 is blocked from external access by UFW"
      else
        warn "UFW is not active — port 4141 may be exposed"
        info "Enable UFW or manually block: ufw deny in on any to any port 4141"
      fi
    else
      warn "No firewall detected — port 4141 may be internet-exposed"
      info "Bind copilot-api to localhost with iptables:"
      info "  iptables -A INPUT -p tcp --dport 4141 ! -s 127.0.0.1 -j DROP"
    fi
  fi

  # --- 3. SSH Hardening ---
  echo ""
  echo -e "  ${BOLD}3. SSH Hardening${NC}"
  echo ""

  local SSHD_CONFIG="/etc/ssh/sshd_config"
  if [ -f "$SSHD_CONFIG" ]; then
    local CURRENT_ROOT_LOGIN
    CURRENT_ROOT_LOGIN=$(grep -E "^\s*PermitRootLogin\s+" "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | tail -1)

    if [ "$CURRENT_ROOT_LOGIN" = "yes" ]; then
      warn "PermitRootLogin is set to 'yes' — direct root login via password is allowed."
      info "Changing to 'prohibit-password' allows key-based root login only."
      ask "Harden SSH root login? [Y/n]"
      read -r HARDEN_SSH
      HARDEN_SSH="${HARDEN_SSH:-Y}"
      if [[ "$HARDEN_SSH" =~ ^[Yy] ]]; then
        # Backup sshd_config
        cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        # Replace PermitRootLogin yes with prohibit-password
        sed -i 's/^\s*PermitRootLogin\s\+yes/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
        # Restart SSH
        if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
          success "PermitRootLogin set to 'prohibit-password' — SSH restarted"
          CHANGES_MADE=true
        else
          warn "Could not restart SSH. Run manually: systemctl restart sshd"
        fi
      else
        warn "Skipped — PermitRootLogin remains 'yes'"
      fi
    elif [ "$CURRENT_ROOT_LOGIN" = "prohibit-password" ] || [ "$CURRENT_ROOT_LOGIN" = "no" ]; then
      success "SSH root login already hardened (PermitRootLogin=$CURRENT_ROOT_LOGIN)"
    else
      info "PermitRootLogin not explicitly set (default is usually 'prohibit-password')"
    fi
  else
    info "sshd_config not found — SSH hardening skipped"
  fi

  # --- 4. Non-root warning ---
  echo ""
  echo -e "  ${BOLD}4. Service Account${NC}"
  echo ""

  if [ "$(id -u)" = "0" ]; then
    warn "You're running as root. Consider creating a dedicated service user."
    info "Running as root means any agent compromise = full system access."
    echo ""
    info "To set up a service user later:"
    info "  adduser --system --shell /bin/bash openclaw"
    info "  mkdir -p /home/openclaw/.openclaw"
    info "  cp -r ~/.openclaw/* /home/openclaw/.openclaw/"
    info "  chown -R openclaw: /home/openclaw"
    info "  Then run OpenClaw as that user: su - openclaw -c 'openclaw gateway start'"
  else
    success "Running as non-root user ($(whoami)) — good practice"
  fi

  echo ""
  if [ "$CHANGES_MADE" = true ]; then
    success "Server hardening complete!"
  else
    info "No hardening changes applied."
  fi
}

main "$@"

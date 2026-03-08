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
  echo -e "${CYAN}║${NC}  ${BOLD}🦞 Clawdboss Setup Wizard${NC}                    ${CYAN}║${NC}"
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

  ask "Agent emoji (e.g., 🤖, 🦊, ⚡)"
  read -r AGENT_EMOJI
  AGENT_EMOJI="${AGENT_EMOJI:-🤖}"

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
  echo "  2) NanoFlow Console  — Web dashboard with chat, file browser, terminal, cost analytics"
  echo "  3) Both              — Discord + NanoFlow Console side by side"
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
  echo "  1) GitHub Copilot proxy (free with Copilot subscription)"
  echo "  2) OpenAI API direct"
  echo "  3) Anthropic API direct"
  echo "  4) Other (manual config later)"
  echo ""
  ask "Choose provider [1/2/3/4]"
  read -r PROVIDER_CHOICE
  PROVIDER_CHOICE="${PROVIDER_CHOICE:-1}"

  case "$PROVIDER_CHOICE" in
    1)
      LLM_PROVIDER="copilot"
      info "Copilot proxy will be configured on localhost:4141"
      info "Make sure copilot-api is running: npx copilot-api start --port 4141"
      COPILOT_API_KEY="copilot-proxy-local"
      ;;
    2)
      LLM_PROVIDER="openai"
      ask "OpenAI API key (sk-...)"
      read -rs OPENAI_DIRECT_KEY
      echo ""
      ;;
    3)
      LLM_PROVIDER="anthropic"
      ask "Anthropic API key (sk-ant-...)"
      read -rs ANTHROPIC_KEY
      echo ""
      ;;
    4)
      LLM_PROVIDER="manual"
      warn "You'll need to configure the model provider in openclaw.json manually"
      ;;
  esac

  echo ""

  # Discord (only if using Discord interface)
  if [ "$USE_DISCORD" = true ]; then
    echo -e "${BOLD}Discord:${NC}"
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
  fi

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
            "apiKey": "${OPENAI_API_KEY}",
            "models": [
                {"id": "gpt-4o", "name": "GPT-4o", "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 16384},
                {"id": "gpt-4o-mini", "name": "GPT-4o Mini", "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 16384}
            ]
        }
    }
    config['agents']['defaults']['model']['primary'] = "openai/gpt-4o"
    config['agents']['defaults']['heartbeat']['model'] = "openai/gpt-4o-mini"
elif llm_provider == "anthropic":
    config['models']['providers'] = {
        "anthropic": {
            "apiKey": "${ANTHROPIC_API_KEY}",
            "models": [
                {"id": "claude-sonnet-4-5-20250514", "name": "Claude Sonnet 4.5", "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 16384}
            ]
        }
    }
    config['agents']['defaults']['model']['primary'] = "anthropic/claude-sonnet-4-5-20250514"

# Skills with keys
if openai_skills_key:
    config['skills']['entries']['openai-image-gen'] = {"apiKey": "${OPENAI_API_KEY}"}
    config['skills']['entries']['openai-whisper-api'] = {"apiKey": "${OPENAI_API_KEY}"}

if elevenlabs_key:
    config['skills']['entries']['sag'] = {"apiKey": "${ELEVENLABS_API_KEY}"}

print(json.dumps(config, indent=2))
PYEOF

  chmod 600 "$CONFIG_FILE"
  success "Config generated with \${VAR} references (permissions: 600)"

  # Clean up exported vars
  unset CB_TEMPLATES_DIR CB_WORKSPACE_DIR CB_OPENCLAW_DIR CB_DISCORD_GUILD CB_DISCORD_OWNER
  unset CB_DISCORD_MAIN_CHANNEL CB_DEPLOY_COMMS CB_DEPLOY_RESEARCH CB_DEPLOY_SECURITY
  unset CB_LLM_PROVIDER CB_OPENAI_SKILLS_KEY CB_ELEVENLABS_KEY
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

  # Try cargo install first, then check for pre-built binary
  if command -v cargo &>/dev/null; then
    info "Installing Graphthulhu via cargo..."
    cargo install graphthulhu 2>&1 | tail -3 \
      && success "Graphthulhu installed via cargo" \
      || warn "Cargo install failed — trying binary download"
  fi

  if ! command -v graphthulhu &>/dev/null; then
    # Try downloading pre-built binary from GitHub releases
    local ARCH
    ARCH=$(uname -m)
    local OS
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')

    info "Downloading Graphthulhu binary..."
    local RELEASE_URL="https://github.com/scottozolmedia/graphthulhu/releases/latest/download/graphthulhu-${OS}-${ARCH}"
    local BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"

    if curl -fsSL -o "$BIN_DIR/graphthulhu" "$RELEASE_URL" 2>/dev/null; then
      chmod +x "$BIN_DIR/graphthulhu"
      success "Graphthulhu binary downloaded to $BIN_DIR/graphthulhu"
    else
      warn "Could not download Graphthulhu. Install manually:"
      warn "  cargo install graphthulhu"
      warn "  OR download from: https://github.com/scottozolmedia/graphthulhu/releases"
      return
    fi
  fi

  register_mcp "graphthulhu" "graphthulhu serve --backend obsidian --vault $VAULT_DIR"
  success "Graphthulhu configured with vault: $VAULT_DIR"
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
    "$PIP_CMD" install --break-system-packages scrapling 2>/dev/null \
      || "$PIP_CMD" install --user scrapling 2>/dev/null \
      || { warn "Could not install Scrapling. Install manually: pip install scrapling"; return; }
    success "Scrapling installed (Python package)"
  else
    warn "pip not found. Install manually: pip install scrapling"
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
      (curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && apt-get update -qq && apt-get install gh -y -qq) 2>/dev/null \
      || warn "Could not install gh CLI automatically. Install manually: https://cli.github.com"
    else
      warn "Install gh CLI manually: https://cli.github.com"
    fi
  fi

  # Install the OpenClaw GitHub skill
  npx clawhub@latest install github 2>/dev/null \
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

  if npx clawhub@latest install humanizer 2>/dev/null; then
    success "Humanizer skill installed"
  else
    # Fallback to git clone
    SKILLS_DIR="$OPENCLAW_DIR/workspace/skills"
    mkdir -p "$SKILLS_DIR"
    if git clone --depth 1 https://github.com/brandonwise/humanizer.git "$SKILLS_DIR/humanizer" 2>/dev/null; then
      success "Humanizer installed from GitHub"
    else
      warn "Could not install Humanizer. Install manually: npx clawhub@latest install humanizer"
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

  if npx clawhub@latest install self-improving-agent 2>/dev/null; then
    success "Self-Improving Agent skill installed"
  else
    warn "Could not install. Install manually: npx clawhub@latest install self-improving-agent"
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

  if npx clawhub@latest install find-skills 2>/dev/null; then
    success "Find Skills installed"
  else
    warn "Could not install. Install manually: npx clawhub@latest install find-skills"
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

  if npx clawhub@latest install marketing-skills 2>/dev/null; then
    success "Marketing Skills installed"
  else
    warn "Could not install. Install manually: npx clawhub@latest install marketing-skills"
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

  if npx clawhub@latest install playwright-mcp 2>/dev/null; then
    success "Playwright MCP skill installed"
  else
    warn "clawhub install failed. Install manually: npx clawhub@latest install playwright-mcp"
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
  echo -e "${GREEN}║${NC}  ${BOLD}✅ Clawdboss Setup Complete!${NC}                 ${GREEN}║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Agent:${NC}     $AGENT_NAME $AGENT_EMOJI"
  echo -e "  ${BOLD}Tier:${NC}      $([ "$TIER_CHOICE" = "1" ] && echo "Solo" || ([ "$TIER_CHOICE" = "2" ] && echo "Team" || echo "Squad"))"
  echo -e "  ${BOLD}Provider:${NC}  $LLM_PROVIDER"
  echo -e "  ${BOLD}Config:${NC}    $CONFIG_FILE"
  echo -e "  ${BOLD}Secrets:${NC}   $ENV_FILE"
  echo -e "  ${BOLD}Workspace:${NC} $OPENCLAW_DIR/workspace"
  echo ""

  if [ "$DEPLOY_COMMS" = true ]; then
    echo -e "  ${BOLD}Comms:${NC}     $COMMS_NAME 📡"
  fi
  if [ "$DEPLOY_RESEARCH" = true ]; then
    echo -e "  ${BOLD}Research:${NC}  $RESEARCH_NAME 🔍"
  fi
  if [ "$DEPLOY_SECURITY" = true ]; then
    echo -e "  ${BOLD}Security:${NC} $SECURITY_NAME 🛡️"
  fi

  echo ""
  echo -e "  ${BOLD}Next steps:${NC}"

  if [ "$LLM_PROVIDER" = "copilot" ]; then
    echo "    1. Start copilot proxy:  npx copilot-api start --port 4141"
    echo "    2. Start OpenClaw:       openclaw gateway start"
  else
    echo "    1. Start OpenClaw:       openclaw gateway start"
  fi

  echo "    2. Check status:         openclaw status"

  if [ "$USE_CONSOLE" = true ]; then
    echo "    3. Start NanoFlow Console:"
    echo "       cd ~/nanoflow-console && HOST=0.0.0.0 PORT=3000 node server-entry.js"
    echo "       Then open http://localhost:3000"
  fi

  if [ "$USE_DISCORD" = true ]; then
    echo "    3. Open Discord and chat with your agent"
  fi
  echo ""
  echo -e "  ${BOLD}Interface:${NC}"
  if [ "$USE_DISCORD" = true ]; then
    echo "    • Discord bot configured"
  fi
  if [ "$USE_CONSOLE" = true ]; then
    echo "    • NanoFlow Console installed at ~/nanoflow-console"
  fi
  echo ""
  echo -e "  ${BOLD}Ecosystem Tools:${NC}"
  if [[ "${INSTALL_CLAWMETRY:-N}" =~ ^[Yy] ]]; then
    echo "    • Clawmetry installed — run: clawmetry (opens localhost:8900)"
  fi
  if [[ "${INSTALL_CLAWSEC:-N}" =~ ^[Yy] ]]; then
    echo "    • ClawSec suite installed — Soul Guardian + advisory feed"
  fi
  echo ""
  echo -e "  ${BOLD}Security:${NC}"
  echo "    • API keys stored in $ENV_FILE (600 permissions)"
  echo "    • Config uses \${VAR} references — no plaintext keys"
  echo "    • All agents have prompt injection defense pre-configured"
  echo "    • Anti-loop rules prevent token-burning attacks"
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

  # Install NanoFlow Console (if selected)
  if [ "$USE_CONSOLE" = true ]; then
    echo ""
    echo -e "${BOLD}--- NanoFlow Console ---${NC}"
    echo ""
    info "Installing NanoFlow Console web dashboard..."

    CONSOLE_DIR="$HOME/nanoflow-console"
    if [ -d "$CONSOLE_DIR" ]; then
      info "Existing installation found at $CONSOLE_DIR — pulling latest..."
      (cd "$CONSOLE_DIR" && git pull --ff-only 2>/dev/null) || warn "Could not update — using existing version"
    else
      if git clone --depth 1 https://github.com/NanoFlow-io/nanoflow-console.git "$CONSOLE_DIR" 2>/dev/null; then
        success "NanoFlow Console cloned to $CONSOLE_DIR"
      else
        warn "Could not clone NanoFlow Console. Install manually:"
        warn "  git clone https://github.com/NanoFlow-io/nanoflow-console.git"
        USE_CONSOLE=false
      fi
    fi

    if [ "$USE_CONSOLE" = true ] && [ -d "$CONSOLE_DIR" ]; then
      (cd "$CONSOLE_DIR" && npm install --silent 2>&1 | tail -3) \
        && success "Dependencies installed" \
        || warn "npm install failed — run manually in $CONSOLE_DIR"

      # Create .env for NanoFlow Console
      CONSOLE_ENV="$CONSOLE_DIR/.env"
      cat > "$CONSOLE_ENV" << CONSOLEEOF
CLAWDBOT_GATEWAY_URL=ws://127.0.0.1:18789
CLAWDBOT_GATEWAY_TOKEN=${GATEWAY_TOKEN}
CONSOLEEOF
      chmod 600 "$CONSOLE_ENV"

      # Build for production
      info "Building NanoFlow Console..."
      (cd "$CONSOLE_DIR" && npm run build 2>&1 | tail -3) \
        && success "NanoFlow Console built successfully" \
        || warn "Build failed — run 'npm run build' manually in $CONSOLE_DIR"

      success "NanoFlow Console ready at $CONSOLE_DIR"
      info "Start with: cd $CONSOLE_DIR && HOST=0.0.0.0 PORT=3000 node server-entry.js"
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
      "$PIP_CMD" install --break-system-packages clawmetry 2>/dev/null \
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

  # ---- Built-in Skills Activation ----
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║${NC}  ${BOLD}Built-in Skills Activation${NC}                  ${GREEN}║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  info "OpenClaw ships with 50+ built-in skills (Whisper transcription,"
  info "Nano Banana Pro image gen, mcporter MCP management, TTS, email, etc.)"
  info "Many need API keys or CLI tools to activate."
  echo ""
  info "The OpenClaw skills wizard will show which are ready and which"
  info "need dependencies — you can install them and set API keys interactively."
  echo ""
  ask "Run OpenClaw skills setup now? (recommended) [Y/n]"
  read -r RUN_SKILLS_SETUP
  RUN_SKILLS_SETUP="${RUN_SKILLS_SETUP:-Y}"

  if [[ "$RUN_SKILLS_SETUP" =~ ^[Yy] ]]; then
    echo ""
    info "Launching OpenClaw skills wizard..."
    echo ""
    openclaw configure --section skills 2>&1 || {
      warn "Skills wizard exited with an error."
      info "You can run it again later: openclaw configure --section skills"
    }
    echo ""
    success "Skills setup complete."
  else
    info "Skipped. Run later with: openclaw configure --section skills"
  fi

  show_summary
}

main "$@"

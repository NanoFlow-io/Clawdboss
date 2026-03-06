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

# Generate a random token
random_token() {
  openssl rand -hex 32 2>/dev/null || python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || head -c 64 /dev/urandom | xxd -p -c 64
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

  if ! command -v node &>/dev/null; then
    error "Node.js not found. Install it first:"
    echo "  curl -fsSL https://openclaw.ai/install.sh | bash"
    exit 1
  fi

  NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
  if [ "$NODE_VERSION" -lt 22 ]; then
    error "Node.js 22+ required (found v$(node -v))"
    exit 1
  fi
  success "Node.js $(node -v)"

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
  echo -e "${BOLD}--- Your Info ---${NC}"
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

  echo ""
}

# ============================================================
# Collect agent info
# ============================================================

collect_agent_info() {
  echo -e "${BOLD}--- Main Agent ---${NC}"
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
  echo -e "${BOLD}--- Agent Tier ---${NC}"
  echo ""
  echo "  1) Solo     — Main agent only (simplest)"
  echo "  2) Team     — Main + Comms + Research agents"
  echo "  3) Squad    — Main + Comms + Research + Security agents"
  echo ""
  ask "Choose tier [1/2/3]"
  read -r TIER_CHOICE
  TIER_CHOICE="${TIER_CHOICE:-1}"

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

  # Discord
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

  cat >> "$ENV_FILE" << ENVEOF

# Discord
DISCORD_BOT_TOKEN=${DISCORD_TOKEN}

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
  export CB_DISCORD_GUILD="$DISCORD_GUILD"
  export CB_DISCORD_OWNER="$DISCORD_OWNER"
  export CB_DISCORD_MAIN_CHANNEL="$DISCORD_MAIN_CHANNEL"
  export CB_DEPLOY_COMMS="$DEPLOY_COMMS"
  export CB_DEPLOY_RESEARCH="$DEPLOY_RESEARCH"
  export CB_DEPLOY_SECURITY="$DEPLOY_SECURITY"
  export CB_LLM_PROVIDER="$LLM_PROVIDER"
  export CB_OPENAI_SKILLS_KEY="${OPENAI_SKILLS_KEY:-}"
  export CB_ELEVENLABS_KEY="${ELEVENLABS_KEY:-}"

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
guild_id = os.environ['CB_DISCORD_GUILD']
owner_id = os.environ['CB_DISCORD_OWNER']
main_channel = os.environ['CB_DISCORD_MAIN_CHANNEL']
deploy_comms = os.environ['CB_DEPLOY_COMMS'] == 'true'
deploy_research = os.environ['CB_DEPLOY_RESEARCH'] == 'true'
deploy_security = os.environ['CB_DEPLOY_SECURITY'] == 'true'
llm_provider = os.environ['CB_LLM_PROVIDER']
openai_skills_key = os.environ.get('CB_OPENAI_SKILLS_KEY', '')
elevenlabs_key = os.environ.get('CB_ELEVENLABS_KEY', '')

with open(os.path.join(templates_dir, "openclaw.template.json")) as f:
    config = json.load(f)

# Fix workspace
config['agents']['list'][0]['workspace'] = workspace_dir

# Fix guild/owner
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

  # Main workspace — copy and personalize using Python for safe substitution
  for f in AGENTS.md SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md; do
    if [ -f "$TEMPLATES_DIR/workspace/$f" ]; then
      python3 -c "
import sys
content = open(sys.argv[1]).read()
replacements = {
    '__AGENT_NAME__': sys.argv[3],
    '__AGENT_PRONOUNS__': sys.argv[4],
    '__AGENT_EMOJI__': sys.argv[5],
    '__USER_NAME__': sys.argv[6],
    '__USER_TIMEZONE__': sys.argv[7],
}
for k, v in replacements.items():
    content = content.replace(k, v)
open(sys.argv[2], 'w').write(content)
" "$TEMPLATES_DIR/workspace/$f" "$WORKSPACE_DIR/$f" \
  "$AGENT_NAME" "$AGENT_PRONOUNS" "$AGENT_EMOJI" "$USER_NAME" "$USER_TIMEZONE"
    fi
  done
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
import sys
content = open(sys.argv[1]).read()
content = content.replace('__USER_NAME__', sys.argv[3])
content = content.replace('__USER_TIMEZONE__', sys.argv[4])
open(sys.argv[2], 'w').write(content)
" "$TEMPLATES_DIR/workspace/USER.md" "$agent_ws/USER.md" "$USER_NAME" "$USER_TIMEZONE"

    cp "$TEMPLATES_DIR/workspace/TOOLS.md" "$agent_ws/TOOLS.md"
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
  echo "    3. Open dashboard:       openclaw dashboard"
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
    # Use mktemp for unpredictable backup filename
    BACKUP=$(mktemp "${CONFIG_FILE}.bak.XXXXXX")
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
  show_summary
}

main "$@"

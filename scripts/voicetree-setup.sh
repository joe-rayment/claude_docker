#!/bin/bash

# Voicetree Setup - Configure MCP connection and optional API keys
# Runs inside the claude-dev container

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RESET="\e[0m"

MCP_JSON="/workspace/.mcp.json"

echo ""
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  Voicetree Setup${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""

# --- Step 1: Configure MCP connection ---
echo -e "${C_BOLD}1. MCP Connection${C_RESET}"
echo -e "${C_DIM}Connects Claude Code to Voicetree's MCP server on your host.${C_RESET}"
echo -e "${C_DIM}Voicetree desktop app must be running with MCP enabled.${C_RESET}"
echo ""

# Detect host gateway (Docker host IP from inside container)
HOST_IP="host.docker.internal"
if ! getent hosts host.docker.internal &>/dev/null 2>&1; then
    HOST_IP=$(ip route | grep default | awk '{print $3}' 2>/dev/null || echo "host.docker.internal")
fi

DEFAULT_PORT="3001"
echo -e "  Host: ${C_BOLD}${HOST_IP}${C_RESET}"
read -p "  MCP port [$DEFAULT_PORT]: " MCP_PORT
MCP_PORT="${MCP_PORT:-$DEFAULT_PORT}"

MCP_URL="http://${HOST_IP}:${MCP_PORT}/mcp"

# Merge into existing .mcp.json or create new
python3 -c "
import json, os
mcp_path = '$MCP_JSON'
try:
    with open(mcp_path, 'r') as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
if 'mcpServers' not in config:
    config['mcpServers'] = {}
config['mcpServers']['voicetree'] = {
    'type': 'http',
    'url': '$MCP_URL'
}
with open(mcp_path, 'w') as f:
    json.dump(config, f, indent=2)
"

echo -e "  ${C_GREEN}✓${C_RESET} MCP configured: ${MCP_URL}"
echo ""

# --- Step 2: Voicetree backend API keys (optional) ---
# Check if voicetree-backend container is reachable
VT_BACKEND_RUNNING=false
if curl -sf http://localhost:8001/health &>/dev/null 2>&1; then
    VT_BACKEND_RUNNING=true
elif curl -sf "http://${HOST_IP}:8001/health" &>/dev/null 2>&1; then
    VT_BACKEND_RUNNING=true
fi

if [ "$VT_BACKEND_RUNNING" = true ]; then
    echo -e "${C_BOLD}2. Backend API Keys${C_RESET}"
    echo -e "${C_DIM}The Voicetree backend uses LLM APIs for text-to-graph processing.${C_RESET}"
    echo -e "${C_DIM}Keys are stored in /workspace/.env (already in .gitignore).${C_RESET}"
    echo ""

    ENV_FILE="/workspace/.env"

    # Check for existing keys
    HAS_GOOGLE_KEY=false
    HAS_OPENAI_KEY=false
    if [ -f "$ENV_FILE" ]; then
        grep -q "GOOGLE_API_KEY=" "$ENV_FILE" 2>/dev/null && HAS_GOOGLE_KEY=true
        grep -q "OPENAI_API_KEY=" "$ENV_FILE" 2>/dev/null && HAS_OPENAI_KEY=true
    fi

    if [ "$HAS_GOOGLE_KEY" = true ]; then
        echo -e "  ${C_GREEN}[✓]${C_RESET} Google API key: configured"
    else
        read -p "  Google API key (blank to skip): " google_key
        if [ -n "$google_key" ]; then
            echo "GOOGLE_API_KEY=$google_key" >> "$ENV_FILE"
            echo -e "  ${C_GREEN}✓${C_RESET} Google API key saved"
        fi
    fi

    if [ "$HAS_OPENAI_KEY" = true ]; then
        echo -e "  ${C_GREEN}[✓]${C_RESET} OpenAI API key: configured"
    else
        read -p "  OpenAI API key (blank to skip): " openai_key
        if [ -n "$openai_key" ]; then
            echo "OPENAI_API_KEY=$openai_key" >> "$ENV_FILE"
            echo -e "  ${C_GREEN}✓${C_RESET} OpenAI API key saved"
        fi
    fi
    echo ""
else
    echo -e "${C_DIM}2. Backend not detected — skipping API key setup.${C_RESET}"
    echo -e "${C_DIM}   Start it with: ./claude-dev --voicetree${C_RESET}"
    echo ""
fi

# --- Step 3: .gitignore ---
if [ -f "/workspace/.gitignore" ]; then
    if ! grep -qxF '.mcp.json' /workspace/.gitignore 2>/dev/null; then
        read -p "Add .mcp.json to .gitignore? (y/n): " add_gitignore
        if [ "$add_gitignore" = "y" ] || [ "$add_gitignore" = "Y" ]; then
            echo '.mcp.json' >> /workspace/.gitignore
            echo -e "${C_GREEN}✓${C_RESET} Added .mcp.json to .gitignore"
        fi
    fi
fi

# --- Summary ---
echo -e "${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo -e "${C_BOLD}  Setup Complete${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Restart Claude Code${C_RESET} to pick up MCP config: ${C_BOLD}cs${C_RESET}"
echo ""
echo -e "${C_YELLOW}Note:${C_RESET} Voicetree agents spawned from the desktop app run on your"
echo -e "  host (not sandboxed in Docker). The desktop app must be running"
echo -e "  for MCP tools to work."
echo ""

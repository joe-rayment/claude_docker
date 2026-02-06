#!/bin/bash

# Detect project dependencies in /workspace
# Returns detected package managers and install commands

WORKSPACE="/workspace"

# Arrays for detected items
declare -a DETECTED_FILES
declare -a DETECTED_MANAGERS
declare -a INSTALL_COMMANDS

# Check for dependency files (skip if already installed)
check_deps() {
    # Node.js
    if [ -f "$WORKSPACE/package.json" ] && [ ! -d "$WORKSPACE/node_modules" ]; then
        DETECTED_FILES+=("package.json")
        if [ -f "$WORKSPACE/pnpm-lock.yaml" ]; then
            DETECTED_MANAGERS+=("pnpm")
            INSTALL_COMMANDS+=("pnpm install")
        elif [ -f "$WORKSPACE/yarn.lock" ]; then
            DETECTED_MANAGERS+=("yarn")
            INSTALL_COMMANDS+=("yarn install")
        else
            DETECTED_MANAGERS+=("npm")
            INSTALL_COMMANDS+=("npm install")
        fi
    fi

    # Python
    if [ -f "$WORKSPACE/requirements.txt" ]; then
        # Check if first non-comment package from requirements.txt is installed
        local first_pkg
        first_pkg=$(grep -m1 -v '^\s*#\|^\s*$' "$WORKSPACE/requirements.txt" 2>/dev/null | sed 's/[>=<!\[].*//' | tr -d '[:space:]')
        if [ -z "$first_pkg" ] || ! pip show "$first_pkg" &>/dev/null; then
            DETECTED_FILES+=("requirements.txt")
            DETECTED_MANAGERS+=("pip")
            INSTALL_COMMANDS+=("pip install --break-system-packages -r requirements.txt")
        fi
    fi

    if [ -f "$WORKSPACE/pyproject.toml" ]; then
        if grep -q "poetry" "$WORKSPACE/pyproject.toml" 2>/dev/null; then
            if [ ! -d "$WORKSPACE/.venv" ]; then
                DETECTED_FILES+=("pyproject.toml")
                DETECTED_MANAGERS+=("poetry")
                INSTALL_COMMANDS+=("poetry install")
            fi
        elif grep -q "uv" "$WORKSPACE/pyproject.toml" 2>/dev/null || [ -f "$WORKSPACE/uv.lock" ]; then
            if [ ! -d "$WORKSPACE/.venv" ]; then
                DETECTED_FILES+=("pyproject.toml")
                DETECTED_MANAGERS+=("uv")
                INSTALL_COMMANDS+=("uv sync")
            fi
        else
            # pip -e . : check for .egg-info directory
            local has_egg_info=false
            ls "$WORKSPACE"/*.egg-info &>/dev/null && has_egg_info=true
            ls "$WORKSPACE"/src/*/*.egg-info &>/dev/null && has_egg_info=true
            if [ "$has_egg_info" = false ]; then
                DETECTED_FILES+=("pyproject.toml")
                DETECTED_MANAGERS+=("pip")
                INSTALL_COMMANDS+=("pip install --break-system-packages -e .")
            fi
        fi
    fi

    # Go
    if [ -f "$WORKSPACE/go.mod" ] && [ ! -f "$WORKSPACE/go.sum" ]; then
        DETECTED_FILES+=("go.mod")
        DETECTED_MANAGERS+=("go")
        INSTALL_COMMANDS+=("go mod download")
    fi

    # Rust
    if [ -f "$WORKSPACE/Cargo.toml" ] && [ ! -d "$WORKSPACE/target" ]; then
        DETECTED_FILES+=("Cargo.toml")
        DETECTED_MANAGERS+=("cargo")
        INSTALL_COMMANDS+=("cargo build")
    fi

    # Ruby
    if [ -f "$WORKSPACE/Gemfile" ] && [ ! -d "$WORKSPACE/vendor/bundle" ]; then
        DETECTED_FILES+=("Gemfile")
        DETECTED_MANAGERS+=("bundler")
        INSTALL_COMMANDS+=("bundle install")
    fi
}

# Run detection
check_deps

# Output mode based on argument
case "${1:-}" in
    --json)
        # JSON output for programmatic use
        echo "{"
        echo "  \"files\": ["
        for i in "${!DETECTED_FILES[@]}"; do
            [ $i -gt 0 ] && echo ","
            echo -n "    \"${DETECTED_FILES[$i]}\""
        done
        echo ""
        echo "  ],"
        echo "  \"managers\": ["
        for i in "${!DETECTED_MANAGERS[@]}"; do
            [ $i -gt 0 ] && echo ","
            echo -n "    \"${DETECTED_MANAGERS[$i]}\""
        done
        echo ""
        echo "  ],"
        echo "  \"commands\": ["
        for i in "${!INSTALL_COMMANDS[@]}"; do
            [ $i -gt 0 ] && echo ","
            echo -n "    \"${INSTALL_COMMANDS[$i]}\""
        done
        echo ""
        echo "  ]"
        echo "}"
        ;;
    --count)
        # Just return count
        echo "${#DETECTED_FILES[@]}"
        ;;
    --commands)
        # Just return install commands, one per line
        for cmd in "${INSTALL_COMMANDS[@]}"; do
            echo "$cmd"
        done
        ;;
    *)
        # Human-readable output (default)
        if [ ${#DETECTED_FILES[@]} -eq 0 ]; then
            echo "No dependency files detected"
            exit 0
        fi

        echo "Detected dependencies:"
        for i in "${!DETECTED_FILES[@]}"; do
            echo "  - ${DETECTED_FILES[$i]} (${DETECTED_MANAGERS[$i]})"
            echo "    Install: ${INSTALL_COMMANDS[$i]}"
        done
        ;;
esac

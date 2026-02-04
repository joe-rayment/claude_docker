#!/bin/bash

# Detect project dependencies in /workspace
# Returns detected package managers and install commands

WORKSPACE="/workspace"

# Arrays for detected items
declare -a DETECTED_FILES
declare -a DETECTED_MANAGERS
declare -a INSTALL_COMMANDS

# Check for dependency files
check_deps() {
    # Node.js
    if [ -f "$WORKSPACE/package.json" ]; then
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
        DETECTED_FILES+=("requirements.txt")
        DETECTED_MANAGERS+=("pip")
        INSTALL_COMMANDS+=("pip install -r requirements.txt")
    fi

    if [ -f "$WORKSPACE/pyproject.toml" ]; then
        DETECTED_FILES+=("pyproject.toml")
        if grep -q "poetry" "$WORKSPACE/pyproject.toml" 2>/dev/null; then
            DETECTED_MANAGERS+=("poetry")
            INSTALL_COMMANDS+=("poetry install")
        elif grep -q "uv" "$WORKSPACE/pyproject.toml" 2>/dev/null || [ -f "$WORKSPACE/uv.lock" ]; then
            DETECTED_MANAGERS+=("uv")
            INSTALL_COMMANDS+=("uv sync")
        else
            DETECTED_MANAGERS+=("pip")
            INSTALL_COMMANDS+=("pip install -e .")
        fi
    fi

    # Go
    if [ -f "$WORKSPACE/go.mod" ]; then
        DETECTED_FILES+=("go.mod")
        DETECTED_MANAGERS+=("go")
        INSTALL_COMMANDS+=("go mod download")
    fi

    # Rust
    if [ -f "$WORKSPACE/Cargo.toml" ]; then
        DETECTED_FILES+=("Cargo.toml")
        DETECTED_MANAGERS+=("cargo")
        INSTALL_COMMANDS+=("cargo build")
    fi

    # Ruby
    if [ -f "$WORKSPACE/Gemfile" ]; then
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

#!/bin/bash
#
# Ralph Refresh Tasks - Regenerate fix_plan.md from a spec file
#
# Uses Claude to regenerate the task list from a project spec,
# preserving completed tasks and removing obsolete ones.
#
# Usage:
#   ralph-refresh              # Auto-detect spec file
#   ralph-refresh spec.md      # Use specified file
#

# Colors
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_RESET="\e[0m"

WORKSPACE="/workspace"
RALPH_DIR="$WORKSPACE/.ralph"
FIX_PLAN="$RALPH_DIR/fix_plan.md"

# Global variable for file selection (avoids stdout capture issues with interactive prompts)
SELECTED_SPEC=""

# Check Claude authentication
check_auth() {
    if [ ! -f "/home/agent/.claude/credentials" ] && ! claude auth status &>/dev/null; then
        echo -e "${C_RED}✗${C_RESET} Claude is not authenticated."
        echo -e "  Run ${C_BOLD}claude auth login${C_RESET} or ${C_BOLD}/login${C_RESET} first."
        exit 1
    fi
}

# Find spec files in the workspace
find_spec_files() {
    local candidates=(
        "$RALPH_DIR/PROMPT.md"
        "$WORKSPACE/spec.md"
        "$WORKSPACE/PROMPT.md"
        "$WORKSPACE/README.md"
        "$WORKSPACE/docs/spec.md"
    )

    local found=()
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            found+=("$f")
        fi
    done

    echo "${found[@]}"
}

# Prompt user to select a spec file
select_spec_file() {
    local arg="$1"

    # If argument provided, use it directly
    if [ -n "$arg" ]; then
        if [ -f "$WORKSPACE/$arg" ]; then
            SELECTED_SPEC="$WORKSPACE/$arg"
            return 0
        elif [ -f "$arg" ]; then
            SELECTED_SPEC="$arg"
            return 0
        else
            echo -e "${C_RED}✗${C_RESET} File not found: $arg"
            return 1
        fi
    fi

    # Auto-detect spec files
    local found_str
    found_str=$(find_spec_files)
    local found=($found_str)

    if [ ${#found[@]} -eq 0 ]; then
        echo -e "${C_YELLOW}⚠${C_RESET} No spec files found in workspace."
        echo ""
        read -p "  Enter path to spec file: " custom_path
        if [ -f "$custom_path" ]; then
            SELECTED_SPEC="$custom_path"
            return 0
        elif [ -f "$WORKSPACE/$custom_path" ]; then
            SELECTED_SPEC="$WORKSPACE/$custom_path"
            return 0
        else
            echo -e "${C_RED}✗${C_RESET} File not found: $custom_path"
            return 1
        fi
    fi

    if [ ${#found[@]} -eq 1 ]; then
        SELECTED_SPEC="${found[0]}"
        echo -e "  ${C_GREEN}✓${C_RESET} Using: ${C_BOLD}${SELECTED_SPEC#$WORKSPACE/}${C_RESET}"
        return 0
    fi

    # Multiple files found — show selection
    echo -e "  ${C_BOLD}Spec files found:${C_RESET}"
    echo ""
    for i in "${!found[@]}"; do
        local display="${found[$i]#$WORKSPACE/}"
        echo -e "  ${C_BOLD}[$((i+1))]${C_RESET} $display"
    done
    echo -e "  ${C_BOLD}[c]${C_RESET} Custom path"
    echo ""
    read -p "  Choice: " choice

    if [ "$choice" = "c" ] || [ "$choice" = "C" ]; then
        read -p "  Enter path to spec file: " custom_path
        if [ -f "$custom_path" ]; then
            SELECTED_SPEC="$custom_path"
            return 0
        elif [ -f "$WORKSPACE/$custom_path" ]; then
            SELECTED_SPEC="$WORKSPACE/$custom_path"
            return 0
        else
            echo -e "${C_RED}✗${C_RESET} File not found: $custom_path"
            return 1
        fi
    fi

    # Validate numeric choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#found[@]} ]; then
        SELECTED_SPEC="${found[$((choice-1))]}"
        return 0
    fi

    echo -e "${C_RED}✗${C_RESET} Invalid choice"
    return 1
}

# Extract completed tasks from existing fix_plan.md
get_completed_tasks() {
    if [ ! -f "$FIX_PLAN" ]; then
        echo ""
        return
    fi
    grep -E '^\s*- \[x\]' "$FIX_PLAN" || true
}

# Count tasks in a fix_plan file
count_tasks() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "0 0 0"
        return
    fi
    local total completed pending
    total=$(grep -cE '^\s*- \[[ x]\]' "$file" 2>/dev/null || echo 0)
    completed=$(grep -cE '^\s*- \[x\]' "$file" 2>/dev/null || echo 0)
    pending=$((total - completed))
    echo "$total $completed $pending"
}

# Main execution
main() {
    echo ""
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Refresh Task List from Spec${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""

    # Step 1: Check auth
    check_auth

    # Step 2: Select spec file
    echo -e "${C_BLUE}Finding spec file...${C_RESET}"
    if ! select_spec_file "$1"; then
        exit 1
    fi
    echo ""

    # Step 3: Read completed tasks from existing plan
    local completed_tasks
    completed_tasks=$(get_completed_tasks)

    # Count before stats
    local before_stats
    before_stats=$(count_tasks "$FIX_PLAN")
    read -r before_total before_completed before_pending <<< "$before_stats"

    # Step 4: Backup existing fix_plan.md
    if [ -f "$FIX_PLAN" ]; then
        cp "$FIX_PLAN" "$FIX_PLAN.bak"
        echo -e "  ${C_GREEN}✓${C_RESET} Backed up fix_plan.md → fix_plan.md.bak"
    fi

    # Step 5: Read spec contents
    local spec_contents
    spec_contents=$(cat "$SELECTED_SPEC")

    echo ""
    echo -e "${C_BLUE}Generating task list with Claude...${C_RESET}"
    echo -e "  ${C_DIM}(this may take a moment)${C_RESET}"

    # Build prompt
    local completed_section=""
    if [ -n "$completed_tasks" ]; then
        completed_section="

The following tasks have already been completed. Keep them as-is (marked [x]) in the output:
$completed_tasks"
    fi

    local prompt="You are a project task planner. Given the following project spec, generate a task list in Markdown checkbox format.

Rules:
- Each task should be a single checkbox item: - [ ] Task description
- Group tasks under logical section headings (## Section Name)
- Tasks should be specific and actionable
- Order tasks by dependency (prerequisites first)
- Do NOT include meta-tasks like 'review' or 'write tests' unless the spec calls for them
${completed_section}

Project spec:
$spec_contents

Output ONLY the Markdown task list, nothing else."

    # Call Claude (strip SDK debug logs that leak to stdout before the markdown)
    local raw_result
    raw_result=$(echo "$prompt" | claude -p "Generate the task list as described." --output-format text 2>/dev/null)
    local result
    result=$(echo "$raw_result" | sed -n '/^#/,$p')

    # Step 6: Write result or restore backup
    if [ -z "$result" ]; then
        echo -e "  ${C_RED}✗${C_RESET} Claude returned empty output"
        if [ -f "$FIX_PLAN.bak" ]; then
            cp "$FIX_PLAN.bak" "$FIX_PLAN"
            echo -e "  ${C_YELLOW}→${C_RESET} Restored from backup"
        fi
        exit 1
    fi

    # Ensure .ralph directory exists
    mkdir -p "$RALPH_DIR"

    echo "$result" > "$FIX_PLAN"
    echo -e "  ${C_GREEN}✓${C_RESET} Task list written to .ralph/fix_plan.md"

    # Step 7: Show task count diff
    local after_stats
    after_stats=$(count_tasks "$FIX_PLAN")
    read -r after_total after_completed after_pending <<< "$after_stats"

    echo ""
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  Task Summary${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    echo -e "             Before   After"
    echo -e "  Total:     ${C_BOLD}${before_total}${C_RESET}        ${C_BOLD}${after_total}${C_RESET}"
    echo -e "  Completed: ${C_GREEN}${before_completed}${C_RESET}        ${C_GREEN}${after_completed}${C_RESET}"
    echo -e "  Pending:   ${C_YELLOW}${before_pending}${C_RESET}        ${C_YELLOW}${after_pending}${C_RESET}"
    echo ""

    # Step 8: Offer to open in editor
    read -p "Open in editor? (y/n): " open_choice
    if [ "$open_choice" = "y" ] || [ "$open_choice" = "Y" ]; then
        hx "$FIX_PLAN"
    fi
}

main "$@"

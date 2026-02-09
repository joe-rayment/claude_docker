# UX Cleanup

## Current Problems

### 1. Two menus that are nearly identical

The quick menu and main menu differ by exactly one option:

```
Quick Menu                   Main Menu
─────────                    ─────────
[1] Start Claude             [1] Start Claude
[m] Full menu                [2] View logs
[s] Shell                    [s] Skip to shell
```

The `[m] Full menu` option exists solely to reach "View logs." This is an extra navigation step for a single item. Users who know the number system (1, 2, s) gain nothing from a stripped-down menu that hides one option behind another keypress.

### 2. No back navigation

- After launching `view-logs` from the main menu, exiting it drops you to the shell — not back to the menu.
- After launching Claude and exiting, you're dropped to the shell with a hint to type `menu`. There's no loop back.
- The `view-logs.sh` script uses `select`/`break` which exits to shell, not to the calling menu.

### 3. `view-logs.sh` is disconnected

`view-logs.sh` is a standalone script with its own `select` loop. When called from the main menu, its "Exit" option breaks to the shell rather than returning to the menu. This happens because `view-logs` is invoked as a subprocess, and the shell `select` `break` ends the script — control returns to `guided-setup.sh`'s `show_main_menu` loop, but only because the `while true` catches it. Actually, re-reading the code: `view-logs` is called at line 204 inside the `while true` loop of `show_main_menu`, so control *does* return to the menu after `view-logs` exits. This part actually works. The issue is specifically after launching Claude (option 1), which `return`s out of the menu entirely.

### 4. Post-Claude exit behavior

After Claude exits (option 1 in either menu), the function `return`s immediately, dropping the user to a bare shell with just a hint: `Type menu for options`. This forces the user to manually re-enter the menu. A more natural flow would loop back to the menu.

---

## Proposed Changes

### Change 1: Merge into a single menu

Eliminate `show_quick_menu()` entirely. Use `show_main_menu()` for all cases. The "full menu" is only 3 options — there's no cognitive load to justify a simplified version.

**What changes:**
- Delete `show_quick_menu()` function
- Update `main()` to always call `show_main_menu()` after setup steps
- Update the `--menu-only` path to call `show_main_menu()` instead of `show_quick_menu()`
- Remove the `[m] Full menu` option (no longer needed)

**Update tests:**
- `experience.bats` tests reference `--menu-only` and check for "Shell" text — update to match new menu text (the unified menu says "Skip to shell" instead of "Shell", so either unify the label or update the test).

### Change 2: Loop back to menu after Claude exits

Instead of `return`ing after Claude exits, loop back to the menu. The user can still exit to shell via `[s]`.

**What changes in `show_main_menu()`:**
```bash
# Before (returns to shell after Claude exits):
1)
    if require_claude_auth; then
        claude --dangerously-skip-permissions
        echo ""
        echo -e "Type menu for options"
        return
    fi
    ;;

# After (stays in menu loop):
1)
    if require_claude_auth; then
        claude --dangerously-skip-permissions
    fi
    ;;
```

Remove the `return` and the hint message. The `while true` loop naturally re-displays the menu. Users who want a shell press `[s]`.

### Change 3: Add a back option to `view-logs.sh`

This is already handled correctly — `view-logs.sh`'s "Exit" breaks out of `select`, the script ends, and control returns to the `while true` loop in `show_main_menu()`. No change needed here.

### Change 4: Normalize menu labels

Use consistent terminology across the single menu:

```
What would you like to do?

  [1] Start Claude
  [2] View logs
  [q] Quit to shell
```

- "Start Claude (interactive)" → "Start Claude" — the parenthetical adds nothing, Claude is always interactive here.
- "Skip to shell" → "Quit to shell" — "skip" implies something is being bypassed; "quit" is standard menu language.
- Change key from `s` to `q` — `q` is the universal quit key, matches `less`, `vim`, `top`, etc.
- Keep `s` as a silent alias for backwards compatibility (accept both `q` and `s`).

### Change 5: Update `container-welcome.sh` routing

Simplify the decision in `container-welcome.sh` — since there's only one menu now, the routing is just "run guided-setup" vs "run guided-setup --menu-only", and the `--menu-only` flag now also calls the same menu function.

Optionally: remove the `--menu-only` flag entirely since both paths now call the same menu. Keep the flag as a no-op for any external callers, or remove it and update `container-welcome.sh`.

---

## Files to Change

| File | Change |
|------|--------|
| `scripts/guided-setup.sh` | Delete `show_quick_menu()`, update `show_main_menu()` labels, remove post-Claude `return`, update `main()` and `--menu-only` handling |
| `scripts/container-welcome.sh` | Simplify routing (optional — works as-is since `--menu-only` will just call the unified menu) |
| `tests/experience.bats` | Update test assertions to match new menu text |

### Change 6: Remove Ralph Wiggum references

`.claude/settings.local.json` contains two stale permission entries referencing "ralph":

```
"Bash(ralph-enable:*)",    (line 29)
"Bash(ralph:*)",           (line 33)
```

These are leftover permissions for a tool/script that no longer exists in the codebase. Remove both entries from the `allow` array.

While cleaning this file, also consider pruning other stale entries — there are hardcoded local paths (e.g., `/Users/joe.rayment/...`) and a malformed permission string (line 38) that appear to be accumulated noise from past sessions rather than intentional configuration.

**Files:** `.claude/settings.local.json`

---

## Files to Change (complete)

| File | Change |
|------|--------|
| `scripts/guided-setup.sh` | Delete `show_quick_menu()`, update `show_main_menu()` labels, remove post-Claude `return`, update `main()` and `--menu-only` handling |
| `scripts/container-welcome.sh` | Simplify routing (optional — works as-is since `--menu-only` will just call the unified menu) |
| `tests/experience.bats` | Update test assertions to match new menu text |
| `.claude/settings.local.json` | Remove `ralph-enable` and `ralph` permission entries |

## What stays the same

- `view-logs.sh` — no changes needed, already works correctly within the menu loop
- Setup flow (Claude auth, Git config, GitHub auth, dependency install) — untouched
- Welcome screen status display — untouched
- All shell aliases — untouched
- `dev-log` system — untouched

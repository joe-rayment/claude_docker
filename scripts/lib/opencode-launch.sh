#!/usr/bin/env bash
#
# opencode-launch.sh -- the ONE per-launch opencode config writer, shared
# by workers_opencode_command (scripts/lib/workers.sh, the dispatch path:
# the headless worker-run) and recon (scripts/recon.sh)
# (claude-orca-c3p.2). Sourced, never executed. bash 3.2
# clean, because lint-bash32.sh scans all of scripts/.
#
# The writer's job: given the model to launch (already resolved -- a
# caller expands an openai/~<family>-latest alias through
# tier_openai_resolve first), the role's reasoning-effort variant, a
# permission mode and an output path, write the opencode config JSON that
# OPENCODE_CONFIG will point at. The provider block follows the model's
# prefix:
#
#   openrouter/<id>  provider.openrouter with the guard's apiKey/baseURL
#                    options when a base URL is given (the local guard is
#                    an OpenRouter-only affair) and reasoning.effort under
#                    the vendor model when a variant is given -- byte for
#                    byte what workers_opencode_command and recon wrote before
#                    there was a second provider, which the frozen tests
#                    (variant-carry, opencode-permissions, recon,
#                    tier-openrouter-auth) pin.
#   openai/<id>      provider.openai with reasoningEffort (opencode's own
#                    variant key for provider openai) -- NEVER an
#                    apiKey/baseURL: opencode's own ChatGPT login supplies
#                    the credential and refreshes it itself.
#   anything else    no provider key at all.
#
# Permission modes: "allow" is the dispatched-worker block (everything
# allowed, git push denied -- claude-orca-gh9), "readonly" is recon's
# (edit/write/git push denied), "ask" opts back into opencode's own
# interactive defaults by writing no permission key at all.

# opencode_launch_config <model> <variant> <allow|readonly|ask> <out-file>
#                        [<openrouter-base-url>]
# Writes the config to <out-file> (umask 077, then chmod 600). The base URL
# rides in only for an openrouter/ model behind a live guard; an empty
# variant omits the models block.
opencode_launch_config() {
    local model="$1" variant="${2:-}" perm="${3:-}" out="$4" base_url="${5:-}"
    local provider_key="" vendor_model="$model"
    local havebase=false havevariant=false

    case "$model" in
        openrouter/*) provider_key="openrouter"; vendor_model="${model#openrouter/}" ;;
        openai/*)     provider_key="openai"; vendor_model="${model#openai/}" ;;
        *)            provider_key="" ;;
    esac
    [ -n "$base_url" ] && havebase=true
    [ -n "$variant" ] && havevariant=true

    ( umask 077 && jq -n \
        --arg perm "$perm" \
        --arg pkey "$provider_key" \
        --arg vm "$vendor_model" \
        --arg eff "$variant" \
        --arg base "$base_url" \
        --argjson havebase "$havebase" \
        --argjson havevariant "$havevariant" \
        '{
            "$schema": "https://opencode.ai/config.json"
          }
          + (if $perm == "allow" then
               { permission: {
                   "*": "allow",
                   bash: { "*": "allow", "git push *": "deny", "git push": "deny" },
                   external_directory: { "*": "allow" } } }
             elif $perm == "readonly" then
               { permission: {
                   "*": "allow",
                   edit: "deny",
                   write: "deny",
                   bash: { "*": "allow", "git push": "deny", "git push *": "deny" },
                   external_directory: { "*": "allow" } } }
             else {} end)
          + (if $pkey == "openrouter" then
               { provider: { openrouter: (
                   { }
                   + (if $havebase then
                        { options: { apiKey: "{env:OPENROUTER_API_KEY}",
                                     baseURL: $base } }
                      else {} end)
                   + (if $havevariant then
                        { models: { ($vm): { options: { reasoning: { effort: $eff } } } } }
                      else {} end) ) } }
             elif $pkey == "openai" then
               { provider: { openai: (
                   { }
                   + (if $havevariant then
                        { models: { ($vm): { options: { reasoningEffort: $eff } } } }
                      else {} end) ) } }
             else {} end)' >"$out" )
    chmod 600 "$out" 2>/dev/null || true
}

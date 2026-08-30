#!/bin/bash
set -euo pipefail

# egress-firewall.sh — opt-in default-deny OUTPUT firewall, allowlisting only
# the services this container talks to (beads_claude_docker-0am). OFF
# everywhere by default: scripts/entrypoint.sh only calls this when
# CLAUDE_DEV_FIREWALL=1 is set, and even then a missing CAP_NET_ADMIN is a
# refusal, never a partial/best-effort apply — a wrong allowlist must never
# brick the container. See knowledge-base/EGRESS_FIREWALL.md.
#
# Usage:
#   egress-firewall.sh              Apply the rules for real. Requires
#                                    CAP_NET_ADMIN (docker run/compose
#                                    --cap-add NET_ADMIN); refuses with a
#                                    clear message and nonzero exit otherwise.
#   egress-firewall.sh --dry-run    Print the rules that WOULD be applied.
#                                    Never calls iptables — safe with or
#                                    without NET_ADMIN, and safe to run just
#                                    to inspect the policy.

ALLOWED_HOSTS=(
    api.anthropic.com
    claude.ai
    statsig.anthropic.com
    sentry.io
    github.com
    api.github.com
    objects.githubusercontent.com
    raw.githubusercontent.com
    registry.npmjs.org
    pypi.org
    files.pythonhosted.org
)

usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [--dry-run]

  (no flag)   Apply a default-deny OUTPUT policy, allowlisting DNS,
              established/related traffic, and (over HTTPS):
$(printf '                %s\n' "${ALLOWED_HOSTS[@]}")
              Requires CAP_NET_ADMIN; refuses with a nonzero exit otherwise.
  --dry-run   Print the rules that would be applied. Touches no live
              iptables state.
EOF
}

# CAP_NET_ADMIN is bit 12 of the capability bitmask (linux/capability.h).
# Read from /proc/self/status rather than a helper binary (capsh/getpcaps
# aren't guaranteed installed), so this check has no extra dependency.
have_net_admin() {
    local cap_eff
    cap_eff=$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null) || return 1
    [ -n "${cap_eff:-}" ] || return 1
    [ $(( (16#${cap_eff}) & (1 << 12) )) -ne 0 ]
}

# Preview only — pure text generation, never executes iptables. Kept in sync
# with apply_rules() below by hand: same policy shape, one printed (with
# hostnames, since nothing is resolved yet) and one applied (with the IPs
# each hostname resolves to at apply time).
dry_run() {
    echo "# egress-firewall.sh --dry-run -- preview only, no live iptables state is touched"
    echo "iptables -F OUTPUT"
    echo "iptables -A OUTPUT -o lo -j ACCEPT"
    echo "iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT"
    echo "iptables -A OUTPUT -p udp --dport 53 -j ACCEPT   # DNS"
    echo "iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT   # DNS"
    echo "# allowlisted hosts (each resolved to its A records, one ACCEPT rule per IP, at apply time):"
    local host
    for host in "${ALLOWED_HOSTS[@]}"; do
        echo "#   iptables -A OUTPUT -p tcp -d <resolved-ip> --dport 443 -j ACCEPT   # ${host}"
    done
    echo "iptables -P OUTPUT DROP"
}

# Real apply — see dry_run() above for the policy this implements. Allow
# rules are added FIRST and the DROP policy set LAST, so the chain is never
# more restrictive than intended even for an instant; a resolution failure
# only warns (that one host stays unreachable), it never aborts the apply.
apply_rules() {
    iptables -F OUTPUT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

    local host ip resolved_any
    for host in "${ALLOWED_HOSTS[@]}"; do
        resolved_any=0
        while IFS= read -r ip; do
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
            resolved_any=1
        done < <(dig +short A "$host" 2>/dev/null)
        if [ "$resolved_any" -eq 0 ]; then
            echo "egress-firewall: WARNING - could not resolve $host; it will be unreachable until the next apply" >&2
        fi
    done

    iptables -P OUTPUT DROP
    echo "egress-firewall: applied default-deny OUTPUT policy."
}

main() {
    case "${1:-}" in
        --dry-run)
            dry_run
            ;;
        "")
            if ! have_net_admin; then
                echo "egress-firewall: refusing to apply -- CAP_NET_ADMIN is not available to this process." >&2
                echo "Run the container with --cap-add NET_ADMIN, or use --dry-run to preview the rules." >&2
                exit 1
            fi
            apply_rules
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"

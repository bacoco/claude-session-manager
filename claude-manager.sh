#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Claude Session Manager
# ═══════════════════════════════════════════════════════════
#
# 3 FONCTIONS INDEPENDANTES:
#
# 1. RENEW PERSO: toutes les 5h, ping le compte perso pour
#    garder sa fenetre active. Tourne TOUJOURS, 24/7,
#    meme si on est sur indien. Meme la nuit.
#
# 2. SWAP indien→perso: quand indien atteint 95% d'usage
#    (lu depuis les fichiers locaux, zero cout API)
#
# 3. SWAP perso→indien: des que indien est dispo apres
#    son reset (~5h). Indien est TOUJOURS prioritaire.
#
# ═══════════════════════════════════════════════════════════

set -u

CREDS_DIR="$HOME/.claude"
CREDS_FILE="$CREDS_DIR/.credentials.json"
PRIMARY_NAME="${CLAUDE_PRIMARY_ACCOUNT:-indien}"
FALLBACK_NAME="${CLAUDE_FALLBACK_ACCOUNT:-perso}"
PRIMARY_CREDS="$CREDS_DIR/.credentials-${PRIMARY_NAME}.json"
FALLBACK_CREDS="$CREDS_DIR/.credentials-${FALLBACK_NAME}.json"
LOG="$HOME/.claude-manager.log"
STATE_FILE="/tmp/claude-account-state"
RATE_LIMITED_AT="/tmp/claude-rate-limited-at"
LAST_RENEW_FILE="/tmp/claude-last-renew-perso"
WINDOW_HOURS=5
CHECK_INTERVAL=300       # 5 min main loop
SWAP_THRESHOLD=95        # Auto-swap indien→perso at this %
RENEW_INTERVAL=18000     # 5h — renew perso every 5h
RECOVERY_INTERVAL=1800   # 30 min — check indien when on perso
MAX_FAILS=3
LONG_RETRY=3600          # 1h after repeated failures
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
    echo "[$(date '+%H:%M:%S')] $1"
}

get_current_account() {
    python3 -c "
import json
try:
    d = json.load(open('$CREDS_FILE'))
    token = d.get('claudeAiOauth', {}).get('accessToken', '')[:30]
    for name in ['$PRIMARY_NAME', '$FALLBACK_NAME']:
        try:
            t = json.load(open(f'$CREDS_DIR/.credentials-{name}.json')).get('claudeAiOauth', {}).get('accessToken', '')[:30]
            if token == t: print(name); exit()
        except: pass
    print('unknown')
except: print('error')
" 2>/dev/null
}

get_usage_pct() {
    python3 "$SCRIPT_DIR/check-usage.py" 2>/dev/null || echo "0"
}

check_account_via_cli() {
    local creds_file=$1
    [ ! -f "$creds_file" ] && return 2

    local backup=$(mktemp)
    cp "$CREDS_FILE" "$backup" 2>/dev/null
    cp "$creds_file" "$CREDS_FILE"

    local output
    output=$(echo "ok" | timeout 30 claude -p "reply with just OK" --max-turns 1 2>&1)
    local rc=$?

    cp "$backup" "$CREDS_FILE" 2>/dev/null
    rm -f "$backup"

    if [ $rc -eq 0 ]; then
        return 0
    elif echo "$output" | grep -qi "rate.limit\|usage.limit\|429\|exceeded"; then
        return 1
    else
        return 2
    fi
}

do_swap() {
    local target_name=$1
    local target_creds="$CREDS_DIR/.credentials-${target_name}.json"

    if [ ! -f "$target_creds" ]; then
        log "ABORT swap: no credentials for $target_name"
        return 1
    fi

    local current=$(get_current_account)
    if [ "$current" != "unknown" ] && [ "$current" != "error" ]; then
        cp "$CREDS_FILE" "$CREDS_DIR/.credentials-${current}.json" 2>/dev/null
    fi

    cp "$target_creds" "$CREDS_FILE"
    echo "$target_name" > "$STATE_FILE"
    log "SWAP: $current -> $target_name"
    return 0
}

do_renew() {
    # Renew a specific account by pinging it
    # In dual mode: always renew perso (fallback) to keep it fresh
    # In single mode: renew the current/only account
    local target_creds="${1:-$CREDS_FILE}"
    local target_name="${2:-current}"

    log "RENEW $target_name: pinging..."

    local backup=$(mktemp)
    cp "$CREDS_FILE" "$backup" 2>/dev/null

    # Switch to target if different from active
    if [ "$target_creds" != "$CREDS_FILE" ] && [ -f "$target_creds" ]; then
        cp "$target_creds" "$CREDS_FILE" 2>/dev/null
    fi

    echo "ok" | timeout 30 claude -p "reply OK" --max-turns 1 >/dev/null 2>&1
    local rc=$?

    # Save refreshed creds back
    if [ "$target_creds" != "$CREDS_FILE" ] && [ -f "$target_creds" ]; then
        cp "$CREDS_FILE" "$target_creds" 2>/dev/null
    fi

    # Restore active account
    cp "$backup" "$CREDS_FILE" 2>/dev/null
    rm -f "$backup"

    if [ $rc -eq 0 ]; then
        date +%s > "$LAST_RENEW_FILE"
        next=$(date -d "+${WINDOW_HOURS} hours +2 minutes" '+%H:%M' 2>/dev/null || echo "~5h")
        log "RENEW $target_name: OK — next at $next"
    else
        # Don't update LAST_RENEW_FILE — will retry in 2 min
        log "RENEW $target_name: FAILED — retry in 2 min"
    fi
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════

log "=== Claude Session Manager started ==="

SWAP_ENABLED=false
if [ -f "$PRIMARY_CREDS" ] && [ -f "$FALLBACK_CREDS" ]; then
    SWAP_ENABLED=true
    log "SWAP: indien (gratuit) = primary, perso (payant) = fallback"
fi
if [ "$SWAP_ENABLED" = true ]; then
    log "RENEW: perso every 5h, 24/7"
else
    log "RENEW: current account every 5h, 24/7"
fi

# Startup: indien first
if [ "$SWAP_ENABLED" = true ]; then
    check_account_via_cli "$PRIMARY_CREDS"
    rc=$?
    if [ $rc -eq 0 ]; then
        do_swap "$PRIMARY_NAME"
        log "Started on indien"
    elif [ $rc -eq 1 ]; then
        log "Indien rate limited, starting on perso"
        date +%s > "$RATE_LIMITED_AT"
        do_swap "$FALLBACK_NAME"
    else
        log "Indien broken, starting on perso"
        do_swap "$FALLBACK_NAME"
    fi
fi

fail_count=0
[ ! -f "$LAST_RENEW_FILE" ] && echo 0 > "$LAST_RENEW_FILE"

# ═══════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════

while true; do
    now=$(date +%s)

    # ─────────────────────────────────────────────────────
    # 1. RENEW PERSO — simple: last_renew + 5h02 = next renew
    #    If renew fails (429) → retry every 2 min until it works
    # ─────────────────────────────────────────────────────
    last_renew=$(cat "$LAST_RENEW_FILE" 2>/dev/null || echo 0)
    next_renew=$((last_renew + RENEW_INTERVAL + 120))  # +2 min margin after window clears

    if [ $now -ge $next_renew ]; then
        if [ "$SWAP_ENABLED" = true ]; then
            target_creds="$FALLBACK_CREDS"
            target_name="perso"
        else
            target_creds="$CREDS_FILE"
            target_name="current"
        fi

        do_renew "$target_creds" "$target_name"
        # Check if it worked — if not, retry in 2 min (don't update LAST_RENEW_FILE)
        # do_renew already writes LAST_RENEW_FILE on success
    fi

    # ─────────────────────────────────────────────────────
    # 2 & 3. SWAP — only if 2 accounts
    # ─────────────────────────────────────────────────────
    if [ "$SWAP_ENABLED" = true ]; then
        current=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

        if [ "$current" = "$PRIMARY_NAME" ]; then
            # === ON INDIEN (gratuit) ===
            # Monitor usage (FREE), swap to perso at 95%
            usage=$(get_usage_pct)

            if [ -f "/tmp/claude-request-swap" ]; then
                rm -f "/tmp/claude-request-swap"
                log "Manual swap (usage: ${usage}%)"
                date +%s > "$RATE_LIMITED_AT"
                do_swap "$FALLBACK_NAME"
            elif [ "$(echo "$usage >= $SWAP_THRESHOLD" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
                log "USAGE ${usage}% >= ${SWAP_THRESHOLD}% — swap to perso"
                date +%s > "$RATE_LIMITED_AT"
                do_swap "$FALLBACK_NAME"
            fi

        elif [ "$current" = "$FALLBACK_NAME" ]; then
            # === ON PERSO (payant) ===
            # Indien is ALWAYS priority — go back ASAP

            if [ -f "$RATE_LIMITED_AT" ]; then
                limited_at=$(cat "$RATE_LIMITED_AT")
                clear_at=$((limited_at + WINDOW_HOURS * 3600))
                remaining=$((clear_at - now))

                if [ $remaining -gt 0 ]; then
                    # Don't block — sleep in chunks so renew can fire
                    chunk=$CHECK_INTERVAL
                    [ $remaining -lt $chunk ] && chunk=$remaining
                    sleep "$chunk"
                    continue
                fi
            fi

            # Window clear — test indien
            log "Testing indien..."
            check_account_via_cli "$PRIMARY_CREDS"
            rc=$?

            if [ $rc -eq 0 ]; then
                do_swap "$PRIMARY_NAME"
                log "Back on indien!"
                fail_count=0
                rm -f "$RATE_LIMITED_AT"
            elif [ $rc -eq 1 ]; then
                log "Indien still limited, +30min"
                date +%s > "$RATE_LIMITED_AT"
            else
                fail_count=$((fail_count + 1))
                retry=$RECOVERY_INTERVAL
                [ $fail_count -ge $MAX_FAILS ] && retry=$LONG_RETRY
                log "Indien broken (#$fail_count), retry ${retry}s"
                sleep "$retry"
                continue
            fi

        else
            check_account_via_cli "$PRIMARY_CREDS"
            if [ $? -eq 0 ]; then
                do_swap "$PRIMARY_NAME"
            else
                do_swap "$FALLBACK_NAME" 2>/dev/null
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done

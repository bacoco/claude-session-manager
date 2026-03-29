#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Claude Session Manager
# ═══════════════════════════════════════════════════════════
#
# 2 PROCESSUS INDEPENDANTS:
#
# PROCESS 1 — RENEW (background, toujours actif)
#   - Renew CHAQUE compte independamment, toutes les 5h02
#   - 24/7, meme la nuit, quel que soit le compte actif
#   - Si fail (429) → retry toutes les 2 min jusqu'a OK
#   - Fonctionne avec 1 ou 2 comptes
#
# PROCESS 2 — SWAP (foreground, seulement si 2 comptes)
#   - Indien = prioritaire (gratuit), perso = fallback (payant)
#   - indien→perso quand usage >= 95%
#   - perso→indien des que indien est dispo (~5h)
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
WINDOW_HOURS=5
CHECK_INTERVAL=300       # 5 min — swap loop
SWAP_THRESHOLD=95        # Auto-swap indien→perso at this %
RENEW_INTERVAL=18000     # 5h
RENEW_MARGIN=120         # 2 min after window clears
RENEW_RETRY=120          # 2 min retry on failure
RECOVERY_INTERVAL=1800   # 30 min — check indien when on perso
MAX_FAILS=3
LONG_RETRY=3600
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
    # Read from real quota cache (updated by statusline every 60s)
    local current=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    local cache="/tmp/claude-quota-cache-${current}.json"
    if [ -f "$cache" ]; then
        python3 -c "import json; print(json.load(open('$cache')).get('util', 0) * 100)" 2>/dev/null || echo "0"
    else
        # Fallback to session file scanning
        python3 "$SCRIPT_DIR/check-usage.py" 2>/dev/null || echo "0"
    fi
}

get_reset_time() {
    # Get real reset timestamp from cache
    local account=$1
    local cache="/tmp/claude-quota-cache-${account}.json"
    if [ -f "$cache" ]; then
        python3 -c "import json; print(json.load(open('$cache')).get('reset', 0))" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

ping_account() {
    # Ping an account via CLI. Temporarily swaps creds, pings, restores.
    # Returns: 0=OK, 1=rate_limited/failed
    local target_creds=$1

    local backup=$(mktemp)
    cp "$CREDS_FILE" "$backup" 2>/dev/null
    cp "$target_creds" "$CREDS_FILE" 2>/dev/null

    echo "ok" | timeout 30 claude -p "reply OK" --max-turns 1 >/dev/null 2>&1
    local rc=$?

    # Save refreshed creds back to the target file
    cp "$CREDS_FILE" "$target_creds" 2>/dev/null
    # Restore active account
    cp "$backup" "$CREDS_FILE" 2>/dev/null
    rm -f "$backup"

    return $rc
}

check_account_via_cli() {
    # Like ping but returns: 0=OK, 1=rate_limited, 2=broken
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

    if [ $rc -eq 0 ]; then return 0
    elif echo "$output" | grep -qi "rate.limit\|usage.limit\|429\|exceeded"; then return 1
    else return 2; fi
}

do_swap() {
    local target_name=$1
    local target_creds="$CREDS_DIR/.credentials-${target_name}.json"
    [ ! -f "$target_creds" ] && { log "ABORT swap: no creds for $target_name"; return 1; }

    local current=$(get_current_account)
    if [ "$current" != "unknown" ] && [ "$current" != "error" ]; then
        cp "$CREDS_FILE" "$CREDS_DIR/.credentials-${current}.json" 2>/dev/null
    fi
    cp "$target_creds" "$CREDS_FILE"
    echo "$target_name" > "$STATE_FILE"
    log "SWAP: $current -> $target_name"
}

# ═══════════════════════════════════════════════════════════
# PROCESS 1 — RENEW (runs in background)
# One independent renew loop per account
# ═══════════════════════════════════════════════════════════

renew_loop() {
    local account_name=$1
    local account_creds=$2
    local cache_file="/tmp/claude-quota-cache-${account_name}.json"

    [ ! -f "$account_creds" ] && return

    while true; do
        local now=$(date +%s)

        # Read REAL reset time from quota cache (updated by statusline every 60s)
        local reset_at=0
        if [ -f "$cache_file" ]; then
            reset_at=$(python3 -c "import json; print(json.load(open('$cache_file')).get('reset', 0))" 2>/dev/null || echo 0)
        fi

        # Renew = reset_time + 2 min
        local renew_at=$((reset_at + RENEW_MARGIN))

        if [ $reset_at -gt 0 ] && [ $now -ge $renew_at ]; then
            local reset_str=$(date -d @$reset_at '+%H:%M' 2>/dev/null || echo "?")
            log "RENEW $account_name: reset was at $reset_str, pinging..."
            if ping_account "$account_creds"; then
                log "RENEW $account_name: OK — waiting for next reset from cache"
            else
                log "RENEW $account_name: FAILED — retry in ${RENEW_RETRY}s"
                sleep "$RENEW_RETRY"
                continue
            fi
        elif [ $reset_at -gt $now ]; then
            # Reset in the future — sleep until then + margin
            local wait=$((renew_at - now))
            local reset_str=$(date -d @$reset_at '+%H:%M' 2>/dev/null || echo "?")
            log "RENEW $account_name: next reset at $reset_str, sleeping ${wait}s"
            sleep "$wait"
            continue
        fi

        # Check every 5 min for cache updates
        sleep "$CHECK_INTERVAL"
    done
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════

log "=== Claude Session Manager started ==="

# Start RENEW loops in background — one per account
ACCOUNTS_FOUND=0
for name_creds in "$PRIMARY_NAME:$PRIMARY_CREDS" "$FALLBACK_NAME:$FALLBACK_CREDS"; do
    acct_name="${name_creds%%:*}"
    acct_creds="${name_creds##*:}"
    if [ -f "$acct_creds" ]; then
        renew_loop "$acct_name" "$acct_creds" &
        log "RENEW $acct_name: started (PID $!, every 5h02, 24/7)"
        ACCOUNTS_FOUND=$((ACCOUNTS_FOUND + 1))
    fi
done

# Determine swap mode
SWAP_ENABLED=false
if [ $ACCOUNTS_FOUND -ge 2 ]; then
    SWAP_ENABLED=true
    log "SWAP: indien (gratuit) = primary, perso (payant) = fallback"
else
    log "SWAP: disabled ($ACCOUNTS_FOUND account(s))"
fi

# If no swap, just wait for renew loops
if [ "$SWAP_ENABLED" = false ]; then
    log "Running renew only. Waiting..."
    wait
    exit 0
fi

# Startup: indien first
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

fail_count=0

# ═══════════════════════════════════════════════════════════
# PROCESS 2 — SWAP (foreground loop)
# ═══════════════════════════════════════════════════════════

while true; do
    now=$(date +%s)
    current=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

    if [ "$current" = "$PRIMARY_NAME" ]; then
        # === ON INDIEN — monitor usage, swap at 95% ===
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
        # === ON PERSO — wait for indien reset, swap back ASAP ===

        # Read REAL reset time from indien quota cache
        indien_reset=$(get_reset_time "$PRIMARY_NAME")
        remaining=0
        if [ "$indien_reset" -gt 0 ] 2>/dev/null; then
            remaining=$((indien_reset + RENEW_MARGIN - now))
        elif [ -f "$RATE_LIMITED_AT" ]; then
            limited_at=$(cat "$RATE_LIMITED_AT")
            remaining=$((limited_at + WINDOW_HOURS * 3600 - now))
        fi

        if [ $remaining -gt 0 ]; then
            chunk=$CHECK_INTERVAL
            [ $remaining -lt $chunk ] && chunk=$remaining
            sleep "$chunk"
            continue
        fi

        # Test indien
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
        if [ $? -eq 0 ]; then do_swap "$PRIMARY_NAME"
        else do_swap "$FALLBACK_NAME" 2>/dev/null; fi
    fi

    sleep "$CHECK_INTERVAL"
done

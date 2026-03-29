#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Claude Session Manager — Smart account swap
# ═══════════════════════════════════════════════════════════
#
# SIMPLE ALGO:
# - indien = preferred, always use it when available
# - perso = safety net, only when indien is rate limited
# - Monitor indien usage via local session files (zero API cost)
# - At 95% usage → swap to perso
# - Periodically check if indien is available again → swap back
# - NEVER swap FROM perso based on usage (perso has no threshold)
#
# Claude uses a 5h SLIDING WINDOW. No pings, no renewals.
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
CHECK_INTERVAL=300       # 5 min — read local files (zero cost)
SWAP_THRESHOLD=95        # Swap indien→perso at this %
RECOVERY_INTERVAL=1800   # 30 min — check indien via CLI when on perso (costs 1 token)
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
    # Read local session files — ZERO API COST
    python3 "$SCRIPT_DIR/check-usage.py" 2>/dev/null || echo "0"
}

check_account_via_cli() {
    # Returns: 0=OK, 1=rate_limited, 2=broken
    # COSTS ~1 TOKEN — only call when needed
    local creds_file=$1
    [ ! -f "$creds_file" ] && return 2

    # Temporarily swap creds to test
    local backup=$(mktemp)
    cp "$CREDS_FILE" "$backup" 2>/dev/null
    cp "$creds_file" "$CREDS_FILE"

    local output
    output=$(echo "ok" | timeout 30 claude -p "reply with just OK" --max-turns 1 2>&1)
    local rc=$?

    # Restore creds
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
    # Swap to target. Checks health first.
    local target_name=$1
    local target_creds="$CREDS_DIR/.credentials-${target_name}.json"

    if [ ! -f "$target_creds" ]; then
        log "ABORT: no credentials for $target_name"
        return 1
    fi

    # Save current
    local current=$(get_current_account)
    if [ "$current" != "unknown" ] && [ "$current" != "error" ]; then
        cp "$CREDS_FILE" "$CREDS_DIR/.credentials-${current}.json" 2>/dev/null
    fi

    cp "$target_creds" "$CREDS_FILE"
    echo "$target_name" > "$STATE_FILE"
    log "SWAP: $current -> $target_name"
    return 0
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════

log "=== Claude Session Manager started ==="

# Check mode
if [ ! -f "$PRIMARY_CREDS" ] || [ ! -f "$FALLBACK_CREDS" ]; then
    log "SINGLE MODE — need 2 credential files for auto-swap"
    log "  Save creds: /account save indien  +  /account save perso"
    while true; do sleep 3600; done
fi

log "DUAL MODE: primary=$PRIMARY_NAME (preferred), fallback=$FALLBACK_NAME (safety net)"

# Start: try indien first
check_account_via_cli "$PRIMARY_CREDS"
rc=$?
if [ $rc -eq 0 ]; then
    do_swap "$PRIMARY_NAME"
    log "Started on $PRIMARY_NAME"
elif [ $rc -eq 1 ]; then
    log "$PRIMARY_NAME rate limited at startup, using $FALLBACK_NAME"
    date +%s > "$RATE_LIMITED_AT"
    do_swap "$FALLBACK_NAME"
else
    log "$PRIMARY_NAME broken, using $FALLBACK_NAME"
    do_swap "$FALLBACK_NAME"
fi

fail_count=0

# ═══════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════

while true; do
    current=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

    if [ "$current" = "$PRIMARY_NAME" ]; then
        # ─── ON INDIEN ───────────────────────────────────
        # Monitor usage by reading local files (FREE)
        # If usage >= 95% → swap to perso
        # If manual swap requested → swap to perso

        usage=$(get_usage_pct)

        # Manual swap request
        if [ -f "/tmp/claude-request-swap" ]; then
            rm -f "/tmp/claude-request-swap"
            log "Manual swap requested (usage: ${usage}%)"
            date +%s > "$RATE_LIMITED_AT"
            do_swap "$FALLBACK_NAME"
        # Usage threshold
        elif [ "$(echo "$usage >= $SWAP_THRESHOLD" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            log "USAGE ${usage}% >= ${SWAP_THRESHOLD}% — swapping to $FALLBACK_NAME"
            date +%s > "$RATE_LIMITED_AT"
            do_swap "$FALLBACK_NAME"
        fi

        sleep "$CHECK_INTERVAL"

    elif [ "$current" = "$FALLBACK_NAME" ]; then
        # ─── ON PERSO ────────────────────────────────────
        # Wait for indien to become available again
        # Strategy:
        #   1. If we know when indien was limited → sleep until clear time
        #   2. Then check indien via CLI (costs 1 token)
        #   3. If OK → swap back to indien
        #   4. If still limited → wait 30 more minutes
        #   5. If broken → wait longer (1h)

        now=$(date +%s)

        # Calculate when indien should be clear
        if [ -f "$RATE_LIMITED_AT" ]; then
            limited_at=$(cat "$RATE_LIMITED_AT")
            clear_at=$((limited_at + WINDOW_HOURS * 3600))
            remaining=$((clear_at - now))

            if [ $remaining -gt 0 ]; then
                log "Sleeping ${remaining}s until $PRIMARY_NAME window clears (~$(date -d @$clear_at '+%H:%M' 2>/dev/null || echo "${remaining}s"))"
                sleep $remaining
                continue
            fi
        fi

        # Window should be clear — test indien (costs 1 token)
        log "Testing $PRIMARY_NAME..."
        check_account_via_cli "$PRIMARY_CREDS"
        rc=$?

        if [ $rc -eq 0 ]; then
            do_swap "$PRIMARY_NAME"
            log "Back on $PRIMARY_NAME!"
            fail_count=0
            rm -f "$RATE_LIMITED_AT"
        elif [ $rc -eq 1 ]; then
            log "$PRIMARY_NAME still limited, waiting ${RECOVERY_INTERVAL}s"
            # Reset timer — still in the window
            date +%s > "$RATE_LIMITED_AT"
            sleep "$RECOVERY_INTERVAL"
            continue
        else
            fail_count=$((fail_count + 1))
            retry=$RECOVERY_INTERVAL
            [ $fail_count -ge $MAX_FAILS ] && retry=$LONG_RETRY
            log "$PRIMARY_NAME broken (fail #$fail_count), retry in ${retry}s"
            sleep "$retry"
            continue
        fi

        sleep "$RECOVERY_INTERVAL"

    else
        # Unknown state — recover
        log "Unknown state, trying $PRIMARY_NAME..."
        check_account_via_cli "$PRIMARY_CREDS"
        if [ $? -eq 0 ]; then
            do_swap "$PRIMARY_NAME"
        else
            do_swap "$FALLBACK_NAME" 2>/dev/null
        fi
        sleep "$CHECK_INTERVAL"
    fi
done

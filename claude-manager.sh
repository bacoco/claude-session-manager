#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Claude Session Manager — Smart account swap
# ═══════════════════════════════════════════════════════════
#
# REALITY: Claude Code uses a SLIDING WINDOW, not fixed blocks.
# - Usage is tracked over the trailing 5 hours
# - Old usage naturally "falls off" after 5h
# - Pinging/renewing does NOTHING — it just adds more usage
#
# ALGO:
# 1. Do NOTHING proactively — zero pings, zero renewals
# 2. When user hits 429 → swap to fallback account
# 3. Record WHEN the 429 happened
# 4. Wait ~5h (sliding window clears) → check primary → swap back
# 5. If fallback also 429 → wait, check periodically
# 6. Never swap to a broken account
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
RATE_LIMITED_AT="/tmp/claude-rate-limited-at"  # epoch when primary got 429
WINDOW_HOURS=5
CHECK_INTERVAL=300  # 5 min between checks when on fallback

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

check_account() {
    # Returns: 0=OK, 1=rate_limited, 2=broken/expired, 3=no_creds
    local creds_file=$1
    [ ! -f "$creds_file" ] && return 3

    local token=$(python3 -c "
import json
try: print(json.load(open('$creds_file')).get('claudeAiOauth',{}).get('accessToken',''))
except: print('')
" 2>/dev/null)

    [ -z "$token" ] && return 2

    local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: Bearer $token" \
        "https://api.claude.ai/api/auth/session" 2>/dev/null)

    case "$status" in
        200) return 0 ;;
        429) return 1 ;;
        401|403) return 2 ;;
        *) return 2 ;;  # network error or unknown
    esac
}

swap_to() {
    local target_name=$1
    local target_creds="$CREDS_DIR/.credentials-${target_name}.json"

    # Check target health BEFORE swapping
    check_account "$target_creds"
    local rc=$?
    if [ $rc -eq 2 ] || [ $rc -eq 3 ]; then
        log "ABORT: $target_name is broken/missing (rc=$rc)"
        return 1
    fi
    if [ $rc -eq 1 ]; then
        log "ABORT: $target_name is also rate limited"
        return 1
    fi

    # Save current creds
    local current=$(get_current_account)
    if [ "$current" != "unknown" ] && [ "$current" != "error" ]; then
        cp "$CREDS_FILE" "$CREDS_DIR/.credentials-${current}.json" 2>/dev/null
    fi

    cp "$target_creds" "$CREDS_FILE"
    echo "$target_name" > "$STATE_FILE"
    log "SWAP: $current -> $target_name"
    return 0
}

# ── Main ───────────────────────────────────────────────────

log "=== Claude Session Manager started ==="

# Detect mode
DUAL_MODE=false
if [ -f "$PRIMARY_CREDS" ] && [ -f "$FALLBACK_CREDS" ]; then
    DUAL_MODE=true
    log "DUAL MODE: primary=$PRIMARY_NAME, fallback=$FALLBACK_NAME"
else
    log "SINGLE MODE: no swap, monitoring only"
fi

# If single mode, just monitor and log — nothing else to do
if [ "$DUAL_MODE" = false ]; then
    log "Nothing to manage in single mode. Exiting."
    log "To enable swap: save creds for 2 accounts via /account save <name>"
    # Stay alive but idle — systemd expects the process to run
    while true; do
        sleep 3600
    done
fi

# Dual mode: ensure we start on primary if possible
check_account "$PRIMARY_CREDS"
primary_status=$?
if [ $primary_status -eq 0 ]; then
    swap_to "$PRIMARY_NAME" || true
    log "Started on $PRIMARY_NAME"
elif [ $primary_status -eq 1 ]; then
    log "$PRIMARY_NAME is rate limited at startup"
    date +%s > "$RATE_LIMITED_AT"
    swap_to "$FALLBACK_NAME" || log "Fallback also unavailable"
else
    log "$PRIMARY_NAME is broken/missing, trying $FALLBACK_NAME"
    swap_to "$FALLBACK_NAME" || log "Both accounts unavailable"
fi

primary_fail_count=0
MAX_FAILS=3
LONG_RETRY=1800  # 30 min

while true; do
    current=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

    if [ "$current" = "$PRIMARY_NAME" ]; then
        # ═══ ON PRIMARY — just monitor for 429 ═══
        check_account "$PRIMARY_CREDS"
        rc=$?
        if [ $rc -eq 1 ]; then
            # Rate limited!
            date +%s > "$RATE_LIMITED_AT"
            estimated_clear=$(date -d "+${WINDOW_HOURS} hours" '+%H:%M' 2>/dev/null || date -v+${WINDOW_HOURS}H '+%H:%M' 2>/dev/null || echo "~5h")
            log "$PRIMARY_NAME rate limited! Estimated clear: $estimated_clear"

            if swap_to "$FALLBACK_NAME"; then
                log "Switched to $FALLBACK_NAME until ~$estimated_clear"
            else
                log "$FALLBACK_NAME unavailable too — waiting on $PRIMARY_NAME"
            fi
        elif [ $rc -eq 2 ]; then
            # Broken
            primary_fail_count=$((primary_fail_count + 1))
            log "$PRIMARY_NAME broken (fail #$primary_fail_count)"
            swap_to "$FALLBACK_NAME" || log "Both accounts down"
        fi
        sleep "$CHECK_INTERVAL"

    elif [ "$current" = "$FALLBACK_NAME" ]; then
        # ═══ ON FALLBACK — wait for primary to clear ═══
        now=$(date +%s)

        # Calculate how long to wait
        if [ -f "$RATE_LIMITED_AT" ]; then
            limited_at=$(cat "$RATE_LIMITED_AT")
            clear_at=$((limited_at + WINDOW_HOURS * 3600))
            remaining=$((clear_at - now))

            if [ $remaining -gt 0 ]; then
                # Still in the window — sleep until clear time
                log "Waiting ${remaining}s for $PRIMARY_NAME sliding window to clear ($(date -d @$clear_at '+%H:%M' 2>/dev/null || echo 'soon'))"
                sleep $remaining
                continue  # Go straight to the check below
            fi
        fi

        # Window should be clear — try primary
        retry_interval=$CHECK_INTERVAL
        [ $primary_fail_count -ge $MAX_FAILS ] && retry_interval=$LONG_RETRY

        check_account "$PRIMARY_CREDS"
        rc=$?
        if [ $rc -eq 0 ]; then
            # Primary is back!
            if swap_to "$PRIMARY_NAME"; then
                log "Back on $PRIMARY_NAME!"
                primary_fail_count=0
                rm -f "$RATE_LIMITED_AT"
            fi
        elif [ $rc -eq 1 ]; then
            # Still rate limited — the window hasn't fully cleared
            # This means heavy usage, extend wait by 30 min
            log "$PRIMARY_NAME still rate limited, extending wait 30min"
            date +%s > "$RATE_LIMITED_AT"  # reset the timer
            sleep 1800
            continue
        else
            # Broken
            primary_fail_count=$((primary_fail_count + 1))
            log "$PRIMARY_NAME still broken (fail #$primary_fail_count), retry in ${retry_interval}s"
        fi

        # Also check if fallback is still OK
        check_account "$FALLBACK_CREDS"
        frc=$?
        if [ $frc -eq 1 ]; then
            log "$FALLBACK_NAME also rate limited now!"
            # Both limited — check if primary cleared
            check_account "$PRIMARY_CREDS"
            [ $? -eq 0 ] && swap_to "$PRIMARY_NAME" && log "Emergency swap back to $PRIMARY_NAME"
        fi

        sleep "$retry_interval"
    else
        # Unknown state — try to recover
        log "Unknown state '$current', attempting recovery..."
        swap_to "$PRIMARY_NAME" || swap_to "$FALLBACK_NAME" || true
        sleep "$CHECK_INTERVAL"
    fi
done

#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Claude Account Manager — Unified session renewal + account swap
# ═══════════════════════════════════════════════════════════
#
# ALGO SIMPLE:
# 1. On est sur indien par defaut
# 2. On track l'heure du dernier message (via inotify sur history.jsonl)
# 3. Si 5h ecoulees depuis premier message du bloc → envoyer ping pour renouveler
# 4. Si on recoit un 429 → swap vers perso
# 5. Calcul du reset = heure du premier message + 5h → on sait EXACTEMENT quand revenir
# 6. A l'heure du reset → swap back indien
# 7. Si un compte est broken → rester sur l'autre, pas de boucle
#
# COUT: quasi zero — pas de polling API, juste inotify + timers
# ═══════════════════════════════════════════════════════════

set -euo pipefail

CREDS_DIR="$HOME/.claude"
CREDS_FILE="$CREDS_DIR/.credentials.json"
INDIEN="$CREDS_DIR/.credentials-indien.json"
PERSO="$CREDS_DIR/.credentials-perso.json"
LOG="$HOME/.claude-manager.log"
STATE_FILE="/tmp/claude-account-state"
BLOCK_START_FILE="/tmp/claude-block-start"
BLOCK_HOURS=5
CHECK_INTERVAL=300  # 5 min — only used as fallback, main trigger is timer-based

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
    try:
        it = json.load(open('$INDIEN')).get('claudeAiOauth', {}).get('accessToken', '')[:30]
        if token == it: print('indien'); exit()
    except: pass
    try:
        pt = json.load(open('$PERSO')).get('claudeAiOauth', {}).get('accessToken', '')[:30]
        if token == pt: print('perso'); exit()
    except: pass
    tier = d.get('claudeAiOauth', {}).get('rateLimitTier', '')
    if 'max_5x' in tier: print('indien')
    elif 'max_20x' in tier: print('perso')
    else: print('unknown')
except: print('error')
" 2>/dev/null
}

is_account_healthy() {
    local creds_file=$1
    [ ! -f "$creds_file" ] && return 1
    
    local token=$(python3 -c "
import json
try: print(json.load(open('$creds_file')).get('claudeAiOauth', {}).get('accessToken', ''))
except: print('')
" 2>/dev/null)
    
    [ -z "$token" ] && return 1
    
    local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: Bearer $token" \
        "https://api.claude.ai/api/auth/session" 2>/dev/null)
    
    # 200 = OK, 429 = rate limited but account works
    [ "$status" = "200" ] || [ "$status" = "429" ]
}

is_rate_limited() {
    local creds_file=${1:-$CREDS_FILE}
    local token=$(python3 -c "
import json
try: print(json.load(open('$creds_file')).get('claudeAiOauth', {}).get('accessToken', ''))
except: print('')
" 2>/dev/null)
    
    [ -z "$token" ] && return 2  # broken
    
    local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: Bearer $token" \
        "https://api.claude.ai/api/auth/session" 2>/dev/null)
    
    case "$status" in
        429) return 0 ;;  # rate limited
        200) return 1 ;;  # OK
        *)   return 2 ;;  # broken/network
    esac
}

swap_to() {
    local target=$1
    local target_file
    [ "$target" = "indien" ] && target_file="$INDIEN" || target_file="$PERSO"
    
    # Check target is healthy BEFORE swapping
    if ! is_account_healthy "$target_file"; then
        log "ABORT swap to $target — account unhealthy"
        return 1
    fi
    
    # Save current creds
    local current=$(get_current_account)
    if [ "$current" = "indien" ]; then
        cp "$CREDS_FILE" "$INDIEN"
    elif [ "$current" = "perso" ]; then
        cp "$CREDS_FILE" "$PERSO"
    fi
    
    cp "$target_file" "$CREDS_FILE"
    echo "$target" > "$STATE_FILE"
    log "SWAP: $current → $target"
    return 0
}

renew_session() {
    # Send minimal message to start a new 5h block
    local account=$1
    log "RENEW: Pinging $account to start new 5h block..."
    echo "hi" | timeout 30 claude --no-input 2>/dev/null || true
    date +%s > "$BLOCK_START_FILE"
    log "RENEW: New block started for $account at $(date)"
}

get_block_reset_time() {
    # Returns epoch time when current block resets (block_start + 5h)
    if [ -f "$BLOCK_START_FILE" ]; then
        local start=$(cat "$BLOCK_START_FILE")
        echo $((start + BLOCK_HOURS * 3600))
    else
        echo 0
    fi
}

# ── Main ───────────────────────────────────────────────────

log "=== Claude Manager started ==="
log "Preferred: indien | Fallback: perso"

# Determine starting account
if is_account_healthy "$INDIEN" && ! is_rate_limited "$INDIEN"; then
    swap_to indien || swap_to perso || log "WARNING: No healthy account!"
    log "Started on indien"
elif is_account_healthy "$PERSO"; then
    swap_to perso
    log "Indien unavailable, started on perso"
    # If indien is rate limited, estimate when it resets
    if is_rate_limited "$INDIEN"; then
        # Assume current block started ~2.5h ago (worst case middle of block)
        echo $(($(date +%s) + BLOCK_HOURS * 1800)) > "$BLOCK_START_FILE"
        log "Indien rate limited — estimated reset in ~2.5h"
    fi
else
    log "WARNING: Both accounts unhealthy! Staying on current"
fi

indien_broken=false

while true; do
    current=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")
    now=$(date +%s)
    
    if [ "$current" = "indien" ]; then
        # === ON INDIEN ===
        # Check if rate limited
        is_rate_limited
        rc=$?
        if [ $rc -eq 0 ]; then
            # Rate limited — record block start (now - 5h), swap to perso
            reset_at=$((now + BLOCK_HOURS * 3600))
            echo "$now" > "$BLOCK_START_FILE"
            log "INDIEN rate limited! Reset at $(date -d @$reset_at '+%H:%M')"
            if swap_to perso; then
                log "On perso until $(date -d @$reset_at '+%H:%M')"
            else
                log "Perso unhealthy too! Waiting on indien..."
            fi
        elif [ $rc -eq 2 ]; then
            # Broken — try perso
            indien_broken=true
            log "INDIEN broken! Trying perso..."
            swap_to perso || log "Both broken, waiting..."
        fi
        # Sleep longer when things are fine
        sleep "$CHECK_INTERVAL"
        
    else
        # === ON PERSO ===
        # Calculate when indien resets
        reset_at=$(get_block_reset_time)
        
        if [ "$reset_at" -gt 0 ] && [ "$now" -ge "$reset_at" ] && [ "$indien_broken" = false ]; then
            # Reset time reached — try indien
            log "Indien reset time reached! Checking..."
            if is_account_healthy "$INDIEN" && ! is_rate_limited "$INDIEN"; then
                swap_to indien && log "Back on indien!" || true
            else
                # Still limited — extend by 30min
                echo $((now + 1800)) > "$BLOCK_START_FILE"
                log "Indien still limited, retry in 30min"
            fi
            sleep "$CHECK_INTERVAL"
        elif [ "$indien_broken" = true ]; then
            # Indien was broken — check every 30min
            if [ $((now % 1800)) -lt "$CHECK_INTERVAL" ]; then
                if is_account_healthy "$INDIEN"; then
                    indien_broken=false
                    log "Indien recovered!"
                    if ! is_rate_limited "$INDIEN"; then
                        swap_to indien || true
                    fi
                fi
            fi
            sleep "$CHECK_INTERVAL"
        else
            # Waiting for reset — sleep until reset time (smart, no wasted cycles)
            if [ "$reset_at" -gt 0 ]; then
                wait_secs=$((reset_at - now))
                if [ "$wait_secs" -gt 0 ] && [ "$wait_secs" -lt 18000 ]; then
                    log "Sleeping ${wait_secs}s until indien resets at $(date -d @$reset_at '+%H:%M')"
                    sleep "$wait_secs"
                    continue  # Skip the default sleep, go straight to check
                fi
            fi
            sleep "$CHECK_INTERVAL"
        fi
    fi
    
    # Renew session if block is about to expire (proactive renewal)
    block_reset=$(get_block_reset_time)
    if [ "$block_reset" -gt 0 ]; then
        time_left=$((block_reset - now))
        if [ "$time_left" -le 300 ] && [ "$time_left" -ge 0 ]; then
            renew_session "$current"
        fi
    fi
done

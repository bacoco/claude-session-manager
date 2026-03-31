#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Claude Session Manager v2.1 — IMMUTABLE ANNUAL TOKENS
# ═══════════════════════════════════════════════════════════
#
# TOKENS ANNUELS: ~/.claude/.token-{name}-annual (chmod 444)
#   → JAMAIS écrasés, JAMAIS copiés, JAMAIS modifiés
#   → Credentials reconstruits à chaque swap/ping
#
# PROCESS 1 — RENEW (2x background)
#   - Ping chaque compte toutes les 5h (schedule 4:02/9:02/14:02/19:02/0:02)
#   - Reconstruit les creds depuis le token annuel à chaque ping
#   - Si fail → retry toutes les 2 min
#
# PROCESS 2 — SWAP (foreground)
#   - indien = prioritaire (gratuit), perso = fallback (payant)
#   - indien→perso quand usage >= 95% (vérifie perso avant)
#   - perso→indien dès que indien est dispo (vérifie indien avant)
#   - Lecture cache locale uniquement (zéro token consommé)
#   - Ping de vérification UNIQUEMENT au moment du swap
#
# CONCURRENCE: flock sur /tmp/claude-creds.lock pour éviter
# les races entre renew loops et swap loop
#
# ═══════════════════════════════════════════════════════════

set -u

CREDS_DIR="$HOME/.claude"
CREDS_FILE="$CREDS_DIR/.credentials.json"
PRIMARY_NAME="${CLAUDE_PRIMARY_ACCOUNT:-indien}"
FALLBACK_NAME="${CLAUDE_FALLBACK_ACCOUNT:-perso}"
LOG="$HOME/.claude-manager.log"
STATE_FILE="/tmp/claude-account-state"
RATE_LIMITED_AT="/tmp/claude-rate-limited-at"
CLAUDE_BIN="$HOME/.local/bin/claude"
TOKEN_DIR="$CREDS_DIR"
LOCK_FILE="/tmp/claude-creds.lock"

CHECK_INTERVAL=300       # 5 min — swap loop check
SWAP_THRESHOLD=95        # swap indien→perso at this %
RENEW_RETRY=120          # 2 min retry on ping failure
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
    echo "[$(date '+%H:%M:%S')] $1"
}

# ═══════════════════════════════════════════════════════════
# BUILD CREDENTIALS FROM ANNUAL TOKEN
# This is the ONLY way credentials are created. Never cp.
# ═══════════════════════════════════════════════════════════

build_creds_json() {
    local name=$1 output=$2
    local token_file="$TOKEN_DIR/.token-${name}-annual"
    [ ! -f "$token_file" ] && { log "ERROR: token file missing: $token_file"; return 1; }
    local token=$(cat "$token_file")
    local sub_type="enterprise" tier="default_claude_max_5x"
    [ "$name" = "perso" ] && { sub_type="max"; tier="default_claude_max_20x"; }
    python3 << PYEOF
import json, time, os
data = {'claudeAiOauth': {
    'accessToken': '$token',
    'refreshToken': '',
    'expiresAt': int((time.time() + 365*24*3600) * 1000),
    'scopes': ['user:file_upload','user:inference','user:mcp_servers','user:profile','user:sessions:claude_code'],
    'subscriptionType': '$sub_type',
    'rateLimitTier': '$tier'
}}
with open('$output', 'w') as f:
    json.dump(data, f)
os.chmod('$output', 0o600)
PYEOF
}

get_current_account() {
    cat "$STATE_FILE" 2>/dev/null || echo "unknown"
}

get_usage_pct() {
    local current=$(get_current_account)
    local cache="/tmp/claude-quota-cache-${current}.json"
    if [ -f "$cache" ]; then
        python3 -c "import json; print(json.load(open('$cache')).get('util', 0) * 100)" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

get_reset_time() {
    local account=$1
    local cache="/tmp/claude-quota-cache-${account}.json"
    if [ -f "$cache" ]; then
        python3 -c "import json; print(json.load(open('$cache')).get('reset', 0))" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# ═══════════════════════════════════════════════════════════
# PING — flock-protected, uses temp creds, never touches backups
# ═══════════════════════════════════════════════════════════

ping_account() {
    local target_name=$1
    (
        # Acquire lock — prevents races between renew loops and swap
        flock -w 60 200 || { log "LOCK FAILED for ping $target_name"; exit 1; }

        local backup=$(mktemp)
        cp "$CREDS_FILE" "$backup" 2>/dev/null

        build_creds_json "$target_name" "$CREDS_FILE" || {
            cp "$backup" "$CREDS_FILE" 2>/dev/null
            rm -f "$backup"
            exit 1
        }

        echo "ok" | timeout 30 "$CLAUDE_BIN" -p "reply OK" --max-turns 1 >/dev/null 2>&1
        local rc=$?

        # RESTORE — DISCARD whatever claude refreshed
        cp "$backup" "$CREDS_FILE" 2>/dev/null
        rm -f "$backup"
        exit $rc
    ) 200>"$LOCK_FILE"
    return $?
}

# ═══════════════════════════════════════════════════════════
# SWAP — flock-protected, rebuilds creds from annual token
# ═══════════════════════════════════════════════════════════

do_swap() {
    local target_name=$1
    local old=$(get_current_account)
    (
        flock -w 60 200 || { log "LOCK FAILED for swap to $target_name"; exit 1; }
        build_creds_json "$target_name" "$CREDS_FILE" || exit 1
    ) 200>"$LOCK_FILE"
    if [ $? -ne 0 ]; then
        log "ABORT swap: cannot build creds for $target_name"
        return 1
    fi
    echo "$target_name" > "$STATE_FILE"
    log "SWAP: $old -> $target_name"
}

# ═══════════════════════════════════════════════════════════
# PROCESS 1 — RENEW (runs in background, one per account)
# Schedule: 4:02, 9:02, 14:02, 19:02, 0:02 (every 5h)
# ═══════════════════════════════════════════════════════════

renew_loop() {
    local account_name=$1
    local token_file="$TOKEN_DIR/.token-${account_name}-annual"
    [ ! -f "$token_file" ] && { log "RENEW $account_name: no annual token, exiting"; return; }

    local ANCHOR_H=4
    local ANCHOR_M=2
    local INTERVAL=18000  # 5h in seconds

    # Find next slot: nearest future (4:02 + N*5h)
    local now=$(date +%s)
    local today_anchor=$(date -d "today ${ANCHOR_H}:$(printf '%02d' $ANCHOR_M):00" +%s 2>/dev/null)
    local target=$today_anchor
    while [ "$target" -le "$now" ]; do
        target=$((target + INTERVAL))
    done

    local target_str=$(date -d @$target '+%H:%M' 2>/dev/null || echo "?")
    log "RENEW $account_name: schedule 4:02/9:02/14:02/19:02/0:02 — next at $target_str"

    # Initial wait
    local wait=$((target - $(date +%s)))
    [ "$wait" -gt 0 ] && sleep "$wait"

    # Ping loop: ping, sleep 5h, repeat. No recalculation.
    while true; do
        log "RENEW $account_name: pinging..."
        if ping_account "$account_name"; then
            log "RENEW $account_name: OK — next in 5h"
            sleep $INTERVAL
        else
            log "RENEW $account_name: FAILED — retry in ${RENEW_RETRY}s"
            sleep "$RENEW_RETRY"
        fi
    done
}

# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════

log "=== Claude Session Manager v2.1 started ==="

# Verify annual tokens
for name in "$PRIMARY_NAME" "$FALLBACK_NAME"; do
    tf="$TOKEN_DIR/.token-${name}-annual"
    if [ -f "$tf" ]; then
        log "TOKEN $name: $(wc -c < "$tf") bytes, perms $(stat -c %a "$tf" 2>/dev/null)"
    else
        log "TOKEN $name: MISSING — $tf"
    fi
done

# Start RENEW loops
ACCOUNTS_FOUND=0
for name in "$PRIMARY_NAME" "$FALLBACK_NAME"; do
    if [ -f "$TOKEN_DIR/.token-${name}-annual" ]; then
        renew_loop "$name" &
        log "RENEW $name: started (PID $!)"
        ACCOUNTS_FOUND=$((ACCOUNTS_FOUND + 1))
    fi
done

SWAP_ENABLED=false
if [ $ACCOUNTS_FOUND -ge 2 ]; then
    SWAP_ENABLED=true
    log "SWAP: $PRIMARY_NAME (gratuit) = primary, $FALLBACK_NAME (payant) = fallback"
else
    log "SWAP: disabled ($ACCOUNTS_FOUND account(s))"
fi

if [ "$SWAP_ENABLED" = false ]; then
    log "Running renew only. Waiting..."
    wait
    exit 0
fi

# Startup: indien direct — no test needed (annual token, renew validates)
do_swap "$PRIMARY_NAME"
log "Started on $PRIMARY_NAME"

# ═══════════════════════════════════════════════════════════
# PROCESS 2 — SWAP (foreground loop)
# ═══════════════════════════════════════════════════════════

while true; do
    now=$(date +%s)
    current=$(get_current_account)

    if [ "$current" = "$PRIMARY_NAME" ]; then
        # === ON INDIEN — monitor usage, swap to perso at 95% ===
        usage=$(get_usage_pct)

        if [ -f "/tmp/claude-request-swap" ]; then
            rm -f "/tmp/claude-request-swap"
            log "Manual swap — verifying $FALLBACK_NAME first..."
            if ping_account "$FALLBACK_NAME"; then
                date +%s > "$RATE_LIMITED_AT"
                do_swap "$FALLBACK_NAME"
            else
                log "ABORT swap: $FALLBACK_NAME is down, staying on $PRIMARY_NAME"
            fi
        elif [ "$(echo "$usage >= $SWAP_THRESHOLD" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            log "USAGE ${usage}% >= ${SWAP_THRESHOLD}% — verifying $FALLBACK_NAME..."
            if ping_account "$FALLBACK_NAME"; then
                do_swap "$FALLBACK_NAME"
                date +%s > "$RATE_LIMITED_AT"
                log "Swapped to $FALLBACK_NAME"
            else
                log "ABORT swap: $FALLBACK_NAME is down, staying on $PRIMARY_NAME at ${usage}%"
            fi
        fi

    elif [ "$current" = "$FALLBACK_NAME" ]; then
        # === ON PERSO — wait for indien reset, swap back ASAP ===
        indien_reset=$(get_reset_time "$PRIMARY_NAME")
        remaining=0
        if [ "$indien_reset" -gt 0 ] 2>/dev/null; then
            remaining=$((indien_reset + 120 - now))
        elif [ -f "$RATE_LIMITED_AT" ]; then
            limited_at=$(cat "$RATE_LIMITED_AT")
            remaining=$((limited_at + 5 * 3600 - now))
        fi

        if [ $remaining -gt 0 ]; then
            chunk=$CHECK_INTERVAL
            [ $remaining -lt $chunk ] && chunk=$remaining
            sleep "$chunk"
            continue
        fi

        # Reset passed — verify indien before swapping back
        log "Testing $PRIMARY_NAME before swap..."
        if ping_account "$PRIMARY_NAME"; then
            do_swap "$PRIMARY_NAME"
            log "Back on $PRIMARY_NAME!"
            rm -f "$RATE_LIMITED_AT"
        else
            log "$PRIMARY_NAME failed — retrying in 5min"
            sleep "$CHECK_INTERVAL"
            continue
        fi

    else
        # === UNKNOWN STATE — find best available (indien priority) ===
        log "Unknown state, finding best available (indien priority)..."
        if ping_account "$PRIMARY_NAME"; then
            do_swap "$PRIMARY_NAME"
            log "Recovered on $PRIMARY_NAME"
        elif ping_account "$FALLBACK_NAME"; then
            do_swap "$FALLBACK_NAME"
            log "Recovered on $FALLBACK_NAME"
        else
            log "BOTH accounts down — retry in 5min"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done

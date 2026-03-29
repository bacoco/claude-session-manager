---
name: account
description: Manage Claude accounts — status, swap, renewal. Falls back to alternative AI tools if all Claude accounts exhausted.
---

## Syntax
```
/account              → show status of all accounts
/account swap         → swap to the other Claude account
/account swap indien  → force switch to indien
/account swap perso   → force switch to perso
/account renew        → force session renewal (start new 5h block)
/account fallback     → show available fallback AI tools
```

## CRITICAL RULES
- **NEVER ask for confirmation** — execute immediately
- **Always show the result** after any action
- Run all commands via Bash tool

## /account (status)

Show status of all accounts:

```bash
echo "=== Claude Accounts ==="

# Active account
ACTIVE=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/.credentials.json'))
token = d.get('claudeAiOauth', {}).get('accessToken', '')[:30]
for name in ['indien', 'perso']:
    try:
        t = json.load(open(f'$HOME/.claude/.credentials-{name}.json')).get('claudeAiOauth', {}).get('accessToken', '')[:30]
        if token == t: print(name); exit()
    except: pass
tier = d.get('claudeAiOauth', {}).get('rateLimitTier', '?')
print(f'unknown ({tier})')
")
echo "  Active: $ACTIVE"

# Check each account health
for name in indien perso; do
    f="$HOME/.claude/.credentials-${name}.json"
    if [ -f "$f" ]; then
        token=$(python3 -c "import json; print(json.load(open('$f')).get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null)
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Authorization: Bearer $token" "https://api.claude.ai/api/auth/session" 2>/dev/null)
        case "$status" in
            200) echo "  $name: ✅ healthy" ;;
            429) echo "  $name: ⚠️ rate limited" ;;
            401|403) echo "  $name: ❌ token expired (run: claude login + /account save $name)" ;;
            *) echo "  $name: ❓ unreachable (status $status)" ;;
        esac
    else
        echo "  $name: ⬜ not configured"
    fi
done

# Daemon status
echo ""
echo "=== Manager Daemon ==="
systemctl --user is-active claude-manager 2>/dev/null && echo "  Status: ✅ running" || echo "  Status: ❌ stopped"
[ -f /tmp/claude-account-state ] && echo "  Managed account: $(cat /tmp/claude-account-state)"
[ -f /tmp/claude-block-start ] && echo "  Block started: $(date -d @$(cat /tmp/claude-block-start) '+%H:%M')" && echo "  Block resets: $(date -d @$(($(cat /tmp/claude-block-start) + 18000)) '+%H:%M')"

# Fallback tools
echo ""
echo "=== Fallback AI Tools ==="
which aider >/dev/null 2>&1 && echo "  aider (Gemini/GPT): ✅ installed" || echo "  aider: ⬜ not installed (pip install aider-chat)"
which codex >/dev/null 2>&1 && echo "  codex (OpenAI): ✅ installed" || echo "  codex: ⬜ not installed (npm i -g @openai/codex)"
echo "  z.ai API: $([ -n \"$LLM_API_KEY_EXCENIA\" ] && echo '✅ key set' || echo '⬜ no key')"
```

Then format the output nicely for the user.

## /account swap [target]

```bash
# Detect current
CURRENT=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/.credentials.json'))
token = d.get('claudeAiOauth', {}).get('accessToken', '')[:30]
for name in ['indien', 'perso']:
    try:
        t = json.load(open(f'$HOME/.claude/.credentials-{name}.json')).get('claudeAiOauth', {}).get('accessToken', '')[:30]
        if token == t: print(name); exit()
    except: pass
print('unknown')
")

# Determine target
TARGET="$1"  # indien or perso, passed from user
if [ -z "$TARGET" ]; then
    [ "$CURRENT" = "indien" ] && TARGET="perso" || TARGET="indien"
fi

# Save current creds
cp "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials-${CURRENT}.json" 2>/dev/null

# Check target exists and is healthy
if [ ! -f "$HOME/.claude/.credentials-${TARGET}.json" ]; then
    echo "❌ No credentials for $TARGET. Run: claude login on that account, then /account save $TARGET"
    exit 1
fi

# Swap
cp "$HOME/.claude/.credentials-${TARGET}.json" "$HOME/.claude/.credentials.json"
echo "$TARGET" > /tmp/claude-account-state
echo "✅ Saved $CURRENT, switched to $TARGET. Restart Claude Code to apply."
```

## /account renew

```bash
echo "Sending ping to start new 5h block..."
echo "hi" | timeout 30 claude --no-input 2>/dev/null
date +%s > /tmp/claude-block-start
echo "✅ New 5h block started at $(date '+%H:%M'). Resets at $(date -d '+5 hours' '+%H:%M')."
```

## /account save [name]

```bash
NAME="$1"
if [ -z "$NAME" ]; then
    echo "Usage: /account save <name> (e.g., /account save indien)"
    exit 1
fi
cp "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials-${NAME}.json"
echo "✅ Current credentials saved as '$NAME'"
```

## /account fallback

If both Claude accounts are exhausted, suggest alternatives:

```
⚠️ Both Claude accounts exhausted. Alternatives:

1. **aider** (uses Gemini/GPT):
   ! aider --model gemini/gemini-2.5-pro

2. **codex** (OpenAI):
   ! codex

3. **z.ai API** (direct, for scripts only):
   Already used by gen_gliner2.py scripts

4. **Wait for reset**:
   Block resets at [time from /tmp/claude-block-start + 5h]
```

Show this info and let the user choose. Do NOT auto-launch other tools.

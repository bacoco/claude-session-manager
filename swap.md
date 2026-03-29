---
name: swap
description: Switch between Claude perso (max 20x) and indien (enterprise 5x). No confirmation, just execute.
---

## CRITICAL RULES
- **NEVER use AskUserQuestion** — execute immediately, no confirmation
- **NEVER ask** "are you sure?" or "which account?" — just do it

## Syntax
```
/swap                → detect current account, switch to the other one
/swap perso          → switch to perso (max 20x)
/swap indien         → switch to indien (enterprise 5x)
/swap status         → show active account
/swap save <account> → save current creds as named backup
```

## Detect current account

### macOS
```bash
security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
tier = d.get('claudeAiOauth', {}).get('rateLimitTier', 'unknown')
if 'max_5x' in tier: print('indien')
elif 'max_20x' in tier: print('perso')
else: print('unknown')
"
```

### Linux
```bash
python3 -c "
import json
d = json.load(open('$HOME/.claude/.credentials.json'))
tier = d.get('claudeAiOauth', {}).get('rateLimitTier', 'unknown')
if 'max_5x' in tier: print('indien')
elif 'max_20x' in tier: print('perso')
else: print('unknown')
"
```

## Switch account

### macOS
```bash
# Read target creds
CREDS=$(security find-generic-password -s "Claude-Code-creds-<TARGET>" -a "$(whoami)" -w 2>/dev/null)
# Replace active
security delete-generic-password -s "Claude Code-credentials" -a "$(whoami)" 2>/dev/null
security add-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w "$CREDS"
```

### Linux
```bash
cp ~/.claude/.credentials-<TARGET>.json ~/.claude/.credentials.json
```

## Save current creds

### macOS
```bash
CREDS=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null)
security delete-generic-password -s "Claude-Code-creds-<ACCOUNT>" -a "$(whoami)" 2>/dev/null
security add-generic-password -s "Claude-Code-creds-<ACCOUNT>" -a "$(whoami)" -w "$CREDS"
```

### Linux
```bash
cp ~/.claude/.credentials.json ~/.claude/.credentials-<ACCOUNT>.json
```

## Behavior

### `/swap` (no argument)
1. Detect current account
2. **AUTO-SAVE current creds** before switching (use Save procedure with detected account name)
3. perso → switch to indien
4. indien → switch to perso
5. Say: "Saved **X**, switched to **Y**. Restart Claude Code."

### `/swap perso` or `/swap indien`
1. Detect current account
2. **AUTO-SAVE current creds** before switching (use Save procedure with detected account name)
3. Switch to requested account
4. Say: "Saved **X**, switched to **Y**. Restart Claude Code."

### `/swap status`
1. Detect current account
2. Say: "Active: **perso** (max 20x)" or "Active: **indien** (enterprise 5x)"

### `/swap save <account>`
1. Save current creds with the given name
2. Say: "Saved current creds as **<account>**."

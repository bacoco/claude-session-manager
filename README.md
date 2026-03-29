# Claude Session Manager

Daemon that monitors your Claude Code usage and automatically swaps between accounts before you hit rate limits.

## How Claude Code Limits Work

Claude Code uses a **5-hour sliding window**. Every API call consumes tokens. Your usage is the sum of all tokens in the last 5 hours. When it exceeds your plan's threshold, you get rate limited (429). Old tokens naturally "fall off" as they age past 5h. There's nothing to "renew" — you just wait.

## What This Tool Does

It reads your local Claude Code session files to track token usage in real time (zero API cost), and swaps to a backup account before you get rate limited.

## Setup Modes

### Mode 1: No credentials saved → does nothing

```
~/.claude/.credentials-*.json  →  none exist
```

The daemon starts, logs "SINGLE MODE", and sleeps forever. No monitoring, no swap. Claude Code works normally.

### Mode 2: One credential saved → usage monitoring only

```
~/.claude/.credentials-indien.json  →  exists
~/.claude/.credentials-perso.json   →  does NOT exist
```

Same as Mode 1. Can't swap with only one account. Logs usage for information.

### Mode 3: Two credentials saved → full auto-swap

```
~/.claude/.credentials-indien.json  →  exists
~/.claude/.credentials-perso.json   →  exists
```

This is the real deal. Full algorithm below.

## Algorithm (Mode 3 — Dual Account)

```
                         START
                           │
                           ▼
              ┌────────────────────────┐
              │  Test PRIMARY account  │
              │  (claude -p "OK")      │
              │  Costs 1 token         │
              └───────────┬────────────┘
                          │
              ┌───────────┼───────────┐
              ▼           ▼           ▼
            200 OK      429         401/err
              │      rate limited    broken
              │           │           │
              ▼           │           ▼
     ┌────────────┐       │    ┌────────────────┐
     │ USE PRIMARY │       │    │ Test FALLBACK   │
     └─────┬──────┘       │    │ (claude -p "OK") │
           │              │    └───────┬────────┘
           ▼              │            │
   ┌───────────────┐      │     ┌──────┼──────┐
   │ Every 5 min:  │      │     ▼      ▼      ▼
   │ read local    │      │   200 OK  429   broken
   │ session files │      │     │      │      │
   │ (zero cost)   │      │     ▼      │      ▼
   └──────┬────────┘      │  USE IT    │   BOTH DOWN
          │               │            │   sleep 30min
          ▼               │            │   retry
   ┌──────────────┐       │            │
   │ usage < 95%  │       │            │
   │ → keep going │       │            │
   │              │       │            │
   │ usage >= 95% │───────┘            │
   │ → SWAP!      │                    │
   └──────────────┘                    │
                                       │
              ┌────────────────────────┘
              ▼
     ┌─────────────────────────────────────┐
     │         SWAP TO FALLBACK            │
     │                                     │
     │  1. Test fallback (claude -p "OK")  │
     │     - If broken → ABORT, stay put   │
     │     - If 429 → ABORT, stay put      │
     │     - If OK → continue              │
     │                                     │
     │  2. Save current creds              │
     │     cp .credentials.json            │
     │        → .credentials-PRIMARY.json  │
     │                                     │
     │  3. Activate fallback               │
     │     cp .credentials-FALLBACK.json   │
     │        → .credentials.json          │
     │                                     │
     │  4. Record swap time                │
     │     echo $(date +%s) > /tmp/...     │
     └─────────────────┬───────────────────┘
                       │
                       ▼
     ┌─────────────────────────────────────┐
     │       ON FALLBACK — WAITING         │
     │                                     │
     │  Calculate: primary clears at       │
     │  = swap_time + 5 hours              │
     │                                     │
     │  SLEEP until that exact time        │
     │  (no polling, no wasted cycles)     │
     │                                     │
     └─────────────────┬───────────────────┘
                       │
                       ▼  (5h later)
     ┌─────────────────────────────────────┐
     │    Test PRIMARY (claude -p "OK")    │
     │    Costs 1 token                    │
     └─────────────────┬───────────────────┘
                       │
              ┌────────┼────────┐
              ▼        ▼        ▼
           200 OK    429     broken
              │    still      │
              │    limited    │
              ▼        │      ▼
     ┌────────────┐    │   extend wait
     │ SWAP BACK  │    │   +30 min
     │ to PRIMARY │    │   then retry
     └────────────┘    └──→ ...
```

## Configuration

### Environment Variables (set in systemd service file)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_PRIMARY_ACCOUNT` | `indien` | Primary account name |
| `CLAUDE_FALLBACK_ACCOUNT` | `perso` | Fallback account name |
| `CLAUDE_TOKEN_BUDGET` | `5000000` | Estimated 5h token budget |
| `CLAUDE_SWAP_THRESHOLD` | `95` | Swap at this usage % |

### Script Constants (in claude-manager.sh)

| Constant | Default | Description |
|----------|---------|-------------|
| `CHECK_INTERVAL` | `300` (5min) | How often to read local usage files |
| `WINDOW_HOURS` | `5` | Sliding window duration |
| `SWAP_THRESHOLD` | `95` | Auto-swap trigger (%) |
| `MAX_FAILS` | `3` | Consecutive check_account failures before long backoff |
| `LONG_RETRY` | `1800` (30min) | Retry interval after repeated failures |

## What Each Check Costs

| Action | Token Cost | When |
|--------|:----------:|------|
| Read local session files | **0** | Every 5 min while on primary |
| `claude -p "OK"` (health check) | **~1 token** | Only at startup + when trying to swap back |
| Sleep | **0** | Most of the time on fallback |

## Install

```bash
git clone https://github.com/bacoco/claude-session-manager.git
cd claude-session-manager
chmod +x install.sh
./install.sh
```

## Save Account Credentials

```bash
# Login to primary account, then in Claude Code:
/account save indien

# Login to fallback account, then in Claude Code:
/account save perso
```

## Commands

```bash
# Service
systemctl --user status claude-manager
systemctl --user restart claude-manager
tail -f ~/.claude-manager.log

# In Claude Code
/account              # show usage + status
/account swap         # manual swap
/account swap indien  # force specific account
/account save myname  # save current creds

# Force swap from terminal (no Claude Code needed)
touch /tmp/claude-request-swap
```

## Files

| File | Description |
|------|-------------|
| `claude-manager.sh` | Main daemon |
| `check-usage.py` | Reads local JSONL files, returns usage % |
| `claude-manager.service` | systemd unit |
| `account.md` | `/account` slash command |
| `swap.md` | `/swap` slash command (legacy) |
| `install.sh` | Install script |
| `uninstall.sh` | Uninstall script |

## FAQ

**Q: Does monitoring consume my Claude usage?**
No. `check-usage.py` reads local files on disk. Zero API calls.

**Q: What about the health check?**
`check_account` runs `claude -p "OK"` which costs ~1 token. It only runs at startup and when checking if the primary account is available again after being rate limited. Not in a loop.

**Q: What if both accounts are dead?**
The daemon stays on whichever was last working and retries every 30 minutes.

**Q: What if I only have one account?**
The daemon does nothing. No monitoring, no overhead.

**Q: Is CLAUDE_TOKEN_BUDGET accurate?**
No. Anthropic doesn't publish exact limits. 5M is a community estimate for Max plans. Adjust if you find a better number.

## License

MIT

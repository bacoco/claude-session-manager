# Claude Session Manager v2.1

Daemon that auto-renews Claude Code sessions and swaps between accounts when rate limited.

Survives reboots, crashes, logout. Zero manual intervention.

## Architecture

### Immutable Annual Tokens

Tokens are stored as **read-only files** (chmod 444), never overwritten:
```
~/.claude/.token-indien-annual    # enterprise 5x
~/.claude/.token-perso-annual     # max 20x
```

Generate with: `claude setup-token` (valid 1 year).

Credentials (`.credentials.json`) are **rebuilt from scratch** at every swap/ping. Claude Code may refresh them during a ping — the refreshed version is **discarded** and the annual token is used again next time.

### Concurrency: flock

All operations touching `.credentials.json` are wrapped in `flock /tmp/claude-creds.lock`. This prevents race conditions between the 2 renew loops and the swap loop running in parallel.

## 3 Independent Processes

### Process 1 & 2 — RENEW (2x background)

Fixed schedule, anchored on 4:02 AM, every 5h:
```
4:02 → 9:02 → 14:02 → 19:02 → 0:02 → 4:02 → ...
```

Both accounts (indien + perso) ping on the same schedule.

```
Sleep until next slot (4:02/9:02/14:02/19:02/0:02)
Ping account (flock → build creds → claude -p "reply OK" → restore)
Success → sleep 5h → ping again (no recalculation)
Failure → retry every 2 min until OK, then resume 5h cycle
```

### Process 3 — SWAP (foreground)

```
Every 5 min: read quota cache of active account → usage %
(zero tokens consumed — local file only)

ON INDIEN (gratuit, preferred):
  usage < 95% → do nothing
  usage >= 95% → ping perso first
    perso OK → swap to perso
    perso down → stay on indien (log ABORT)

ON PERSO (payant, fallback):
  Read indien cache → reset time
  Sleep until reset + 2 min (in 5-min chunks)
  Ping indien first
    indien OK → swap back to indien
    indien down → retry in 5 min

UNKNOWN STATE:
  Try indien first (priority)
  indien down → try perso
  Both down → retry in 5 min
```

Indien is **always priority**. As soon as it's available, swap back. Every swap **verifies the destination** before switching.

## Schedule Rationale

Renew anchored at 4:02 AM optimized for active hours ~7h-19h:
- **4:02**: Night. Window starts unused. Wake up with near-full quota + imminent reset.
- **9:02**: Morning. Fresh window for core work.
- **14:02**: After lunch. Fresh window for afternoon.
- **19:02**: End of day. Bonus if still working.
- **0:02**: Night. Maintenance.

Zero gaps during active hours (7h-19h). Resets align with natural breaks.

## How Reset Times Are Known

Claude Code's statusline writes quota info to `/tmp/claude-quota-cache-{account}.json` every 60 seconds:
```json
{"util": 0.53, "reset": 1774789200}
```
- `util`: usage fraction (0.53 = 53%)
- `reset`: unix timestamp of next reset

The swap loop reads these files. No API calls for monitoring.

## Install

```bash
git clone https://github.com/bacoco/claude-session-manager.git
cd claude-session-manager
chmod +x install.sh
./install.sh
```

### Generate annual tokens

```bash
# Login with indien account first, then:
claude setup-token
# Copy token to ~/.claude/.token-indien-annual
chmod 444 ~/.claude/.token-indien-annual

# Login with perso account, then:
claude setup-token
# Copy token to ~/.claude/.token-perso-annual
chmod 444 ~/.claude/.token-perso-annual
```

## Persistence

| Event | Behavior |
|-------|----------|
| Reboot | Auto-starts (systemd enabled + linger) |
| Crash | Restarts in 30s (Restart=always) |
| Logout | Keeps running (linger=yes) |
| Network down | Retries, doesn't crash |

## Cost

| Action | Tokens | When |
|--------|:------:|------|
| Read quota cache | **0** | Every 5 min (swap loop) |
| Renew ping | **~1** | Every 5h per account (10/day) |
| Swap verification | **~1** | Only when actually swapping |
| Total per day | **~12** | Negligible |

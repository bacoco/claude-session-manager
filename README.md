# Claude Session Manager

Daemon that auto-renews Claude Code sessions and swaps between accounts when rate limited.

Survives reboots, crashes, logout. Zero manual intervention.

## 3 Independent Modules

### Module 1 — RENEW INDIEN (background process)

```
Read /tmp/claude-quota-cache-indien.json → reset: 15:00
Sleep until 15:02
Ping indien (1 token)
Success → loop, wait for next reset from cache
Failure → retry every 2 min until OK
```

### Module 2 — RENEW PERSO (background process)

```
Read /tmp/claude-quota-cache-perso.json → reset: 13:00
Sleep until 13:02
Ping perso (1 token)
Success → loop, wait for next reset from cache
Failure → retry every 2 min until OK
```

Both renew modules run 24/7, independently, even at night. They read the **real reset time** from quota cache files (updated by Claude Code statusline every 60s). No guessing.

### Module 3 — SWAP (foreground process, only if 2 accounts)

```
Every 5 min: read quota cache of active account → usage %

ON INDIEN (gratuit, preferred):
  usage < 95% → do nothing
  usage >= 95% → swap to perso

ON PERSO (payant, fallback):
  Read indien cache → reset time
  Sleep until reset + 2 min
  Test indien via CLI (1 token)
  OK → swap back to indien
  Still limited → retry in 5 min
  Broken → retry in 5 min (max 3 fails, then 1h)
```

Indien is **always priority**. As soon as it's available, swap back.

## How Reset Times Are Known

Claude Code's statusline writes quota info to `/tmp/claude-quota-cache-{account}.json` every 60 seconds:

```json
{"util": 0.53, "reset": 1774789200}
```

- `util`: usage as fraction (0.53 = 53%)
- `reset`: unix timestamp of next reset

The daemon reads these files. No API calls needed for monitoring.

## Setup Modes

| Config | What runs |
|--------|-----------|
| **No creds saved** | Nothing. Daemon sleeps. |
| **1 account** | RENEW only for that account. |
| **2 accounts** | RENEW both + SWAP at 95%. |

## Install

```bash
git clone https://github.com/bacoco/claude-session-manager.git
cd claude-session-manager
chmod +x install.sh
./install.sh
```

### Save credentials

```bash
# Login to indien, then in Claude Code:
/account save indien

# Login to perso, then in Claude Code:
/account save perso
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
| Read quota cache | **0** | Every 5 min |
| Renew ping | **~1** | At each reset time (~every 5h per account) |
| Test indien (swap back) | **~1** | After indien reset, once |
| Total per day | **~10** | Negligible |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_PRIMARY_ACCOUNT` | `indien` | Preferred account (free) |
| `CLAUDE_FALLBACK_ACCOUNT` | `perso` | Backup account (paid) |

### Constants (claude-manager.sh)

| Constant | Default | Description |
|----------|---------|-------------|
| `CHECK_INTERVAL` | 300 (5min) | Main loop + retry frequency |
| `SWAP_THRESHOLD` | 95 | Swap at this usage % |
| `RENEW_MARGIN` | 120 (2min) | Wait after reset before pinging |
| `RENEW_RETRY` | 120 (2min) | Retry interval if renew fails |
| `RECOVERY_INTERVAL` | 300 (5min) | Recheck indien when on perso |
| `MAX_FAILS` | 3 | Failures before long retry |
| `LONG_RETRY` | 3600 (1h) | Retry after repeated failures |

## Commands

```bash
# Service
systemctl --user status claude-manager
systemctl --user restart claude-manager
systemctl --user stop claude-manager
tail -f ~/.claude-manager.log

# In Claude Code
/account              # show status + usage + next reset
/account swap          # manual swap
/account save indien   # save credentials

# Force swap from terminal
touch /tmp/claude-request-swap

# Check next renew/reset times
python3 -c "
import json, datetime
for name in ['indien', 'perso']:
    d = json.load(open(f'/tmp/claude-quota-cache-{name}.json'))
    print(f'{name}: {d[\"util\"]*100:.0f}% usage, reset {datetime.datetime.fromtimestamp(d[\"reset\"]).strftime(\"%H:%M\")}')
"
```

## Files

| File | Description |
|------|-------------|
| `claude-manager.sh` | Main daemon (3 modules) |
| `check-usage.py` | Fallback: scan JSONL if no cache |
| `claude-manager.service` | systemd unit |
| `account.md` | `/account` slash command |
| `swap.md` | `/swap` slash command |
| `install.sh` | Install |
| `uninstall.sh` | Uninstall |

## Cache Files

| File | Updated by | Content |
|------|-----------|---------|
| `/tmp/claude-quota-cache-indien.json` | statusline (60s) | `{util, reset}` |
| `/tmp/claude-quota-cache-perso.json` | statusline (60s) | `{util, reset}` |
| `/tmp/claude-last-renew-indien` | daemon | epoch of last renew |
| `/tmp/claude-last-renew-perso` | daemon | epoch of last renew |
| `/tmp/claude-account-state` | daemon | active account name |

## License

MIT

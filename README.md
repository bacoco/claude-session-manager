# Claude Session Manager

Daemon that keeps your Claude Code sessions alive and swaps between accounts automatically.

Survives reboots, crashes, logout. Zero manual intervention.

## What It Does

### 3 independent functions:

**1. RENEW (always active, even 1 account)**
- Every 5h: pings Claude to keep the sliding window active
- 24/7, even at night
- In dual mode: renews the fallback (perso) account specifically, so it's always ready
- In single mode: renews your only account
- Cost: 1 token per ping

**2. SWAP indien→perso (dual mode only)**
- Monitors indien usage by reading local session files (zero API cost)
- At 95% usage → auto-swap to perso
- Also supports manual swap via `touch /tmp/claude-request-swap`

**3. SWAP perso→indien (dual mode only)**
- Indien is ALWAYS priority (free enterprise account)
- When indien hits limit, records the time
- Calculates when window clears (limit_time + 5h)
- Sleeps until then, checks indien, swaps back immediately
- If still limited → extends wait 30min, retries

## Algo

```
                 ┌─────────────────────────┐
                 │        START             │
                 │  systemd / boot / crash  │
                 └────────────┬────────────┘
                              │
                 ┌────────────▼────────────┐
                 │  2 credential files?     │
                 │  indien.json + perso.json│
                 └─────┬──────────┬────────┘
                       │YES       │NO
                       ▼          ▼
              DUAL MODE      SINGLE MODE
              (swap+renew)   (renew only)
                       │          │
                       ▼          │
              ┌────────────┐      │
              │ Test indien │      │
              └──┬───┬───┬─┘      │
                 │   │   │        │
               OK  429  err       │
                 │   │   │        │
                 ▼   ▼   ▼        │
              indien perso perso   │
                 │   │   │        │
          ┌──────▼───▼───▼────────▼─┐
          │                         │
          │      MAIN LOOP          │
          │      every 5 min        │
          │                         │
          ├─────────────────────────┤
          │                         │
          │  1. RENEW (always)      │
          │     every 5h:           │
          │     dual → ping perso   │
          │     single → ping self  │
          │                         │
          ├─────────────────────────┤
          │                         │
          │  2. SWAP (dual only)    │
          │                         │
          │  ON INDIEN:             │
          │    read local files     │
          │    (zero cost)          │
          │    if usage >= 95%      │
          │    → swap to perso      │
          │    record limit time    │
          │                         │
          │  ON PERSO:              │
          │    sleep until           │
          │    limit_time + 5h      │
          │    test indien (1 tok)  │
          │    if OK → swap back    │
          │    if 429 → wait +30min │
          │    if err → wait +1h    │
          │                         │
          └─────────────────────────┘
```

## Setup Modes

| Config | What happens |
|--------|-------------|
| **No creds saved** | Daemon sleeps. Nothing happens. |
| **1 account** | RENEW only. Pings every 5h to keep window active. |
| **2 accounts** | RENEW perso 24/7 + SWAP at 95% + auto swap back to indien. |

## Install

```bash
git clone https://github.com/bacoco/claude-session-manager.git
cd claude-session-manager
chmod +x install.sh
./install.sh
```

Installs:
- systemd user service (auto-start at boot, auto-restart on crash, survives logout)
- `/account` + `/swap` slash commands in Claude Code

### Save credentials

```bash
# On the indien account:
claude login
# Then in Claude Code:
/account save indien

# On the perso account:
claude login
# Then in Claude Code:
/account save perso
```

## Persistence

| Event | Behavior |
|-------|----------|
| **Reboot** | Auto-starts (systemd enabled + linger) |
| **Crash** | Auto-restarts in 30s (Restart=always) |
| **Logout** | Keeps running (linger=yes) |
| **Network down** | Retries, doesn't crash |
| **Both accounts dead** | Stays on last working, retries every 30min |

## Cost

| Action | Tokens | When |
|--------|:------:|------|
| Read local session files | **0** | Every 5 min (usage monitoring) |
| Renew ping | **~1** | Every 5h (keep window active) |
| Health check indien | **~1** | Only when testing swap back |
| Sleep | **0** | Most of the time |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_PRIMARY_ACCOUNT` | `indien` | Preferred account (free) |
| `CLAUDE_FALLBACK_ACCOUNT` | `perso` | Backup account (paid) |

### Constants (claude-manager.sh)

| Constant | Default | Description |
|----------|---------|-------------|
| `CHECK_INTERVAL` | 300 (5min) | Main loop frequency |
| `SWAP_THRESHOLD` | 95 | Auto-swap at this % |
| `RENEW_INTERVAL` | 18000 (5h) | Renew ping frequency |
| `RECOVERY_INTERVAL` | 1800 (30min) | Retry indien when limited |
| `LONG_RETRY` | 3600 (1h) | Retry indien when broken |
| `MAX_FAILS` | 3 | Failures before long retry |

## Commands

```bash
# Service
systemctl --user status claude-manager
systemctl --user restart claude-manager
systemctl --user stop claude-manager
tail -f ~/.claude-manager.log
cat /tmp/claude-account-state

# In Claude Code
/account              # status
/account swap          # manual swap
/account save indien   # save current creds

# Force swap from terminal
touch /tmp/claude-request-swap
```

## Files

| File | Description |
|------|-------------|
| `claude-manager.sh` | Main daemon |
| `check-usage.py` | Reads local JSONL, returns usage % |
| `claude-manager.service` | systemd unit |
| `account.md` | `/account` slash command |
| `swap.md` | `/swap` slash command |
| `install.sh` | Install |
| `uninstall.sh` | Uninstall |

## License

MIT

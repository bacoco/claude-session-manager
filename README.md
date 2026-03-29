# Claude Session Manager

Unified daemon for Claude Code: **auto-swap between accounts** + **session renewal**.

## What it does

```
indien (preferred)  ←→  perso (fallback)
        │                     │
        │ rate limited?       │ indien reset?
        │ account broken?     │ account healthy?
        ▼                     ▼
   swap to perso         swap back indien
   sleep until reset     (exact time, no polling)
```

- **Default account**: indien (enterprise 5x)
- **Fallback**: perso (max 20x) — used only when indien hits rate limit
- **Smart sleep**: calculates exact reset time (block start + 5h), no wasteful polling
- **Health checks**: never swaps to a broken account (expired token, 401, network error)
- **Session renewal**: pings Claude 5min before block expiry to start a new 5h window
- **Crash-safe**: systemd auto-restarts on failure, persists across reboots

## Install

```bash
git clone <this-repo>
cd claude-session-manager
chmod +x install.sh
./install.sh
```

## Prerequisites

Save credentials for both accounts:

```bash
# Login to indien account
claude login
# In Claude Code:
/swap save indien

# Login to perso account
claude login
# In Claude Code:
/swap save perso
```

This creates `~/.claude/.credentials-indien.json` and `~/.claude/.credentials-perso.json`.

## Commands

```bash
# Service management
systemctl --user status claude-manager
systemctl --user restart claude-manager
systemctl --user stop claude-manager

# Logs
tail -f ~/.claude-manager.log

# Current account
cat /tmp/claude-account-state

# Manual swap (in Claude Code)
/swap              # toggle
/swap indien       # force indien
/swap perso        # force perso
/swap status       # show active
```

## How it works

1. Starts on **indien** (if healthy)
2. Every 5min: lightweight health check (single curl, ~10ms)
3. If indien returns 429 (rate limited):
   - Records timestamp → calculates reset = now + 5h
   - Checks perso is healthy → swaps
   - **Sleeps until exact reset time** (no polling!)
4. At reset time: checks indien → swaps back
5. If account is broken (401/403): stays on working account, retries every 30min
6. 5min before block expiry: sends minimal ping to renew

## Files

| File | Purpose |
|------|---------|
| `claude-manager.sh` | Main daemon script |
| `claude-manager.service` | systemd unit file |
| `swap.md` | `/swap` slash command for Claude Code |
| `install.sh` | One-command install |
| `uninstall.sh` | Clean uninstall |

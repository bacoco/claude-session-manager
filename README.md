# Claude Session Manager

Lightweight daemon that keeps your Claude Code sessions alive and automatically manages multiple accounts.

## The Problem

Claude Code uses a **sliding window**: your usage over the trailing 5 hours is tracked. When it exceeds the threshold, you get 429 rate limited. Old usage naturally falls off after 5h. There's nothing to "renew" or "ping" — you just have to wait.

If you have two accounts, you can swap to the other one while waiting. That's what this tool does.

## What This Does

### Single Account (default)
Monitors your account. Logs when you get rate limited and estimates when it clears. That's it — there's nothing to "renew" with a sliding window.

### Dual Account (the real value)
If you configure two accounts (e.g. work + personal):
- Uses your **primary account** by default
- When primary gets 429 → checks fallback is healthy → **swaps immediately**
- Records when the 429 happened → calculates when the sliding window clears (now + 5h)
- **Sleeps until clear time** (no polling waste)
- At clear time → checks primary → swaps back
- If primary is still limited (heavy usage) → extends wait 30min
- Never swaps to a broken account (expired token, 401, network error)
- If both accounts 429 → stays put, waits for whichever clears first

### Safety
- **Checks before every swap**: target must be healthy (200) before copying credentials
- **Backoff on broken accounts**: 3 failures → 30min retry interval
- **Survives reboots**: systemd service, auto-restart on crash
- **Minimal resource usage**: sleeps most of the time. One `curl` check (~10ms) only when needed

## Quick Start

```bash
git clone https://github.com/bacoco/claude-session-manager.git
cd claude-session-manager
chmod +x install.sh
./install.sh
```

This installs:
- `claude-manager` systemd user service (starts at boot, auto-restarts on crash)
- `/account` slash command in Claude Code
- `/swap` slash command in Claude Code

### That's it for single account mode. It just works.

### Optional: Enable dual account swap

Save credentials for both accounts:

```bash
# Login to your primary account
claude login
# Then in Claude Code:
/account save work

# Login to your fallback account
claude login
# Then in Claude Code:
/account save personal
```

Configure account names (default: `indien` / `perso`):

```bash
# In your ~/.config/systemd/user/claude-manager.service, add:
Environment=CLAUDE_PRIMARY_ACCOUNT=work
Environment=CLAUDE_FALLBACK_ACCOUNT=personal
```

## How It Works

```
                    ┌──────────────┐
                    │  Start       │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Only 1 acct? ├──YES──► Session renewal only
                    └──────┬───────┘        (ping every 5h)
                           │ NO
                    ┌──────▼───────┐
                    │ Primary OK?  ├──YES──► Use primary
                    └──────┬───────┘        Check every 5min
                           │ NO
                    ┌──────▼───────┐
                    │ Rate limited │
                    │ or broken?   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Fallback OK? ├──NO──► Stay put, wait
                    └──────┬───────┘
                           │ YES
                    ┌──────▼───────┐
                    │ Swap to      │
                    │ fallback     │
                    └──────┬───────┘
                           │
                    ┌──────▼───────────────┐
                    │ Calculate reset time  │
                    │ = now + 5 hours       │
                    └──────┬───────────────┘
                           │
                    ┌──────▼───────┐
                    │ SLEEP until  │  ◄── no polling!
                    │ reset time   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Primary OK?  ├──YES──► Swap back
                    └──────┬───────┘
                           │ NO
                           └──► Extend wait 30min, retry
```

## Commands

### System

```bash
systemctl --user status claude-manager     # daemon status
systemctl --user restart claude-manager    # restart
systemctl --user stop claude-manager       # stop
tail -f ~/.claude-manager.log              # live logs
cat /tmp/claude-account-state              # current account
```

### In Claude Code

```bash
/account                # show status of all accounts + daemon
/account swap           # toggle to other account
/account swap work      # force specific account
/account renew          # force new 5h block now
/account save myname    # save current creds as "myname"
/account fallback       # show alternative AI tools if both accounts dead

/swap                   # quick toggle (legacy, still works)
/swap status            # show active account
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_PRIMARY_ACCOUNT` | `indien` | Name of preferred account |
| `CLAUDE_FALLBACK_ACCOUNT` | `perso` | Name of fallback account |

### Tunable Constants (in claude-manager.sh)

| Constant | Default | Description |
|----------|---------|-------------|
| `BLOCK_HOURS` | `5` | Claude's rolling window duration |
| `CHECK_INTERVAL` | `300` | Seconds between health checks (5min) |
| `MAX_INDIEN_FAILS` | `3` | Consecutive failures before long backoff |
| `LONG_RETRY` | `1800` | Seconds to wait after repeated failures (30min) |

## Files

| File | Description |
|------|-------------|
| `claude-manager.sh` | Main daemon — handles swap + renewal |
| `claude-manager.service` | systemd unit — auto-start, auto-restart |
| `account.md` | `/account` slash command for Claude Code |
| `swap.md` | `/swap` slash command (legacy, still works) |
| `install.sh` | One-command install |
| `uninstall.sh` | Clean uninstall |

## Credential Files

Stored in `~/.claude/`:

| File | Created by |
|------|------------|
| `.credentials.json` | Claude Code (active account) |
| `.credentials-<name>.json` | `/account save <name>` |

The daemon copies between these files to swap accounts. No tokens are stored in the repo.

## FAQ

**Q: I only have one account. Does this do anything?**
Not much. It monitors and logs when you get rate limited. The real value is dual-account swap.

**Q: What if both accounts are dead?**
The daemon waits. It calculates when the primary resets and sleeps until then. No wasted CPU.

**Q: Does this consume Claude usage?**
No. Health checks use `curl` against the auth endpoint — zero token consumption. No pings, no messages sent.

**Q: What if a token expires?**
The daemon detects 401/403, marks the account as broken, and stays on the working account. Run `claude login` + `/account save <name>` to refresh.

**Q: Can I add more than 2 accounts?**
Not currently. The daemon handles primary + fallback. PRs welcome.

## License

MIT

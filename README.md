# Claude Session Manager

Lightweight daemon that keeps your Claude Code sessions alive and automatically manages multiple accounts.

## The Problem

Claude Code has two usage limits:
- **5-hour rolling window**: starts when you send your first message, resets 5h later
- **Weekly cap**: hard limit per billing week

If you don't send a message when your 5h window resets, you lose time. If you hit the limit on one account, you're stuck waiting.

## What This Does

### Single Account (default, zero config)
If you only have one Claude account, the daemon:
- Tracks when your 5h block started
- Automatically pings Claude 5 minutes before the block expires to start a new one
- Keeps your sessions rolling 24/7 with zero gaps
- That's it. No swap, no complexity.

### Dual Account (optional)
If you configure two accounts (e.g. work + personal):
- Uses your **primary account** by default
- If primary hits rate limit (429) → checks fallback is healthy → swaps
- **Calculates the exact reset time** (block start + 5h) and sleeps until then (no polling)
- At reset time → checks primary → swaps back
- Never swaps to a broken account (expired token, 401, network error)
- If both accounts are exhausted → stays on whichever was last working, waits for reset

### Safety Guarantees
- **Never swaps blindly**: always checks target account health before swapping
- **Never loops on broken accounts**: after 3 failures, backs off to 30min retry
- **Survives reboots**: systemd service with auto-restart
- **Zero resource usage**: no polling loop, no npm packages, no API scraping. Just `sleep` + one `curl` check when needed (~10ms)

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
Yes. It auto-renews your 5h session block so you never lose time between blocks.

**Q: What if both accounts are dead?**
The daemon waits. It calculates when the primary resets and sleeps until then. No wasted CPU.

**Q: Does this consume Claude usage?**
The renewal ping sends one minimal message every 5 hours. Health checks use `curl` against the auth endpoint (zero token usage).

**Q: What if a token expires?**
The daemon detects 401/403, marks the account as broken, and stays on the working account. Run `claude login` + `/account save <name>` to refresh.

**Q: Can I add more than 2 accounts?**
Not currently. The daemon handles primary + fallback. PRs welcome.

## License

MIT

#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Claude Session Manager — Install script
# ═══════════════════════════════════════════════════════════
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="claude-manager"

echo "Installing Claude Session Manager..."

# 1. Make executable
chmod +x "$SCRIPT_DIR/claude-manager.sh"

# 2. Install systemd user service
mkdir -p ~/.config/systemd/user
sed "s|ExecStart=.*|ExecStart=$SCRIPT_DIR/claude-manager.sh|" \
    "$SCRIPT_DIR/claude-manager.service" > ~/.config/systemd/user/claude-manager.service

# 3. Enable lingering (run even when logged out)
loginctl enable-linger "$(whoami)" 2>/dev/null || true

# 4. Enable and start
systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user start "$SERVICE_NAME"

# 5. Install /swap command for Claude Code
mkdir -p ~/.claude/commands
cp "$SCRIPT_DIR/swap.md" ~/.claude/commands/swap.md

echo ""
echo "✅ Installed and running!"
echo ""
echo "Commands:"
echo "  systemctl --user status claude-manager    # status"
echo "  tail -f ~/.claude-manager.log             # live logs"
echo "  cat /tmp/claude-account-state             # active account"
echo "  systemctl --user restart claude-manager   # restart"
echo "  systemctl --user stop claude-manager      # stop"
echo ""
echo "In Claude Code:"
echo "  /swap              # toggle indien/perso"
echo "  /swap status       # show active account"
echo ""
echo "Prerequisites:"
echo "  ~/.claude/.credentials-indien.json   # indien account creds"
echo "  ~/.claude/.credentials-perso.json    # perso account creds"
echo "  Run 'claude login' on each account, then '/swap save indien' or '/swap save perso'"

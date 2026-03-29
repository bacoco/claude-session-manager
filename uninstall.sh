#!/bin/bash
set -e
echo "Uninstalling Claude Session Manager..."
systemctl --user stop claude-manager 2>/dev/null || true
systemctl --user disable claude-manager 2>/dev/null || true
rm -f ~/.config/systemd/user/claude-manager.service
systemctl --user daemon-reload
echo "✅ Uninstalled"

#!/usr/bin/env python3
"""Check Claude Code usage in the 5h sliding window.
Returns: exit code 0 if OK, 1 if >= threshold, 2 if error.
Prints usage percentage to stdout."""
import json, sys, os, glob
from datetime import datetime, timezone, timedelta

BUDGET = int(os.environ.get("CLAUDE_TOKEN_BUDGET", 5_000_000))
THRESHOLD = int(os.environ.get("CLAUDE_SWAP_THRESHOLD", 95))

now = datetime.now(timezone.utc)
cutoff = now - timedelta(hours=5)

total_billed = 0
api_calls = 0

# Scan all recent session files
projects_dir = os.path.expanduser("~/.claude/projects/")
for project in glob.glob(f"{projects_dir}/*/"):
    for f in glob.glob(f"{project}/*.jsonl"):
        try:
            mtime = os.path.getmtime(f)
            if (now.timestamp() - mtime) > 6 * 3600:
                continue
        except:
            continue

        try:
            for line in open(f):
                try:
                    d = json.loads(line)
                    ts_str = d.get("timestamp", "")
                    if not isinstance(ts_str, str) or not ts_str:
                        continue
                    ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                    if ts < cutoff:
                        continue
                    usage = d.get("message", {}).get("usage", {})
                    if "input_tokens" in usage:
                        total_billed += usage["input_tokens"]
                        total_billed += usage["output_tokens"]
                        total_billed += usage.get("cache_creation_input_tokens", 0)
                        api_calls += 1
                except:
                    continue
        except:
            continue

pct = total_billed / BUDGET * 100 if BUDGET else 0
print(f"{pct:.1f}")

if pct >= THRESHOLD:
    sys.exit(1)  # Over threshold
sys.exit(0)  # OK

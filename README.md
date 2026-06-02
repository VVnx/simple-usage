# Usage

A tiny macOS menu bar app that shows only Codex and Claude usage.

Usage keeps the essentials visible: 5-hour limits, weekly limits, and reset times for Codex and Claude. No dashboards, no extra providers, no settings clutter.

## What It Shows

- Codex 5-hour usage percentage and reset time
- Codex weekly usage percentage and reset time
- Claude 5-hour usage percentage and reset time
- Claude weekly usage percentage and reset time

The menu bar item is intentionally minimal: one `AI` entry. Click it to see the details.

## Data Sources

- Codex: reads `~/.codex/auth.json` and calls `https://chatgpt.com/backend-api/wham/usage`
- Claude: reads `~/.claude/.credentials.json` or the macOS Keychain item `Claude Code-credentials`, then calls `https://api.anthropic.com/api/oauth/usage`

Usage refreshes every 5 minutes in the background. Use `Command+R` from the menu to refresh manually.

## Requirements

- macOS 14 or newer
- Swift 6 or newer to build from source
- Logged-in Codex CLI and Claude Code accounts

## Build

```bash
./build_app.sh
open Usage.app
```

The build script creates an ad-hoc signed `Usage.app` in the repository root.

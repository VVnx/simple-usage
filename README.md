# Usage

A tiny macOS status bar app for Codex and Claude usage.

Usage shows only the essentials: 5-hour usage, weekly usage, reset times, and the last successful update time for Codex and Claude. No dashboards, no extra providers, no settings clutter.

![Usage screenshot](docs/screenshot.png)

## Features

- Codex 5-hour and weekly usage percentages
- Claude 5-hour and weekly usage percentages
- Reset times with day/hour/minute countdowns
- Separate last-updated timestamps for Codex and Claude
- Background refresh every 5 minutes
- Manual refresh with `Command+R`
- Quick links to the Codex and Claude usage pages

## Data Sources

- Codex: reads `~/.codex/auth.json` and calls `https://chatgpt.com/backend-api/wham/usage`
- Claude: reads `~/.claude/.credentials.json` or the macOS Keychain item `Claude Code-credentials`, then calls `https://api.anthropic.com/api/oauth/usage`

## Requirements

- macOS 14 or newer
- Swift 6 or newer to build from source
- Logged-in Codex CLI and Claude Code accounts

## Build Locally

```bash
./build_app.sh
open Usage.app
```

The build script creates an ad-hoc signed `Usage.app` in the repository root.

## Easiest Way To Use

Download this project locally, open it with Codex, and ask Codex to build and run the app for you:

```text
Build this project, create Usage.app, and run it.
```

Codex can run the included `build_app.sh` script and open the generated app.

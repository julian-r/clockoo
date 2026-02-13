# Clockoo

⏱️ A lightweight macOS menu bar app for Odoo time tracking.

No Electron. No browser. Native Swift. ~10-20 MB memory.

Part of the Odoo tooling family: [vodoo](https://github.com/julian-r/vodoo) (CLI) · [ghoodoo](https://github.com/julian-r/ghoodoo) (GitHub sync) · **clockoo** (time tracking)

![Clockoo demo](docs/demo.gif)

## Download

Grab the latest release from **[Releases](https://github.com/julian-r/clockoo/releases)** — download `Clockoo.dmg` or `Clockoo.app.zip`, unzip, and drag to `/Applications`.

> **First launch:** macOS will block the app ("kann nicht geöffnet werden"). Right-click the app → **Open**, or go to System Settings → Privacy & Security → click **Open Anyway**.

## Features

- 🕐 **Menu bar icon** with live elapsed time when a timer is running
- 🔍 **Search** — find tasks, tickets, and recent timesheets to start a timer on
- ▶️ **Start / Stop** timers with a click (matches Odoo's task UI)
- 🗑️ **Delete** timesheet entries
- 🔗 **Open in browser** — jump to the task or ticket in Odoo
- 👥 **Multi-account** — multiple Odoo instances side by side
- 🔐 **Keychain storage** — API keys never touch config files
- 🎛️ **Stream Deck API** — local HTTP server for integrations ([docs](docs/API.md))
- ⚡ **Optimistic UI** — actions feel instant, server confirms in background
- 🔔 **Blink when idle** — orange pulsing icon when no timer is running
- 🚀 **Launch at login**
- 🌐 **Dual API** — JSON-2 (Odoo 19+) and legacy JSON-RPC (Odoo 14-18)
- 📦 **Zero dependencies** — pure Swift, AppKit + SwiftUI

## Getting Started

### 1. Launch Clockoo

Download from [Releases](https://github.com/julian-r/clockoo/releases) or build from source (see below).

### 2. Add an Account

Click the clock icon in the menu bar → **Settings** → click **+** to add an account:

| Field | Example |
|-------|---------|
| ID | `work` |
| Label | `My Company` |
| URL | `https://mycompany.odoo.com` |
| Database | `mycompany` |
| Username | `user@example.com` |
| API Version | JSON-2 (Odoo 19+) or Legacy (Odoo 14-18) |

### 3. Enter API Key

In the account settings, paste your Odoo API key and click **Test Connection**.

Generate an API key in Odoo: *Preferences → Account Security → API Keys → New API Key*.

### 4. Track Time

- Your today's timesheets appear in the popover
- Use the **search bar** to find tasks, tickets, or recent timesheets
- Click ▶ to start, ■ to stop, 🗑 to delete
- Click ↗ to open the task/ticket in Odoo

## Settings

Open from the popover's gear icon:

- **Accounts** — add, edit, remove, test connection, pick API version
- **General** — launch at login, blink when idle

## Building from Source

```bash
git clone https://github.com/julian-r/clockoo.git
cd clockoo
./build.sh
open Clockoo.app
```

Requires macOS 14+ and Swift 5.10+.

## Architecture

```
┌─────────────────────────────────────────────┐
│ MenuBarController (NSStatusItem)            │
│   └─ TimerPopoverView (SwiftUI)             │
│       └─ Search bar + timer list            │
├─────────────────────────────────────────────┤
│ AccountManager (@MainActor, ObservableObject)│
│   ├─ OdooTimerService (per account)         │
│   │   └─ OdooJSONRPCClient                  │
│   │       ├─ JSON-2: /json/2/<model>/<method>│
│   │       └─ Legacy: /jsonrpc (execute_kw)  │
│   └─ Optimistic state management            │
├─────────────────────────────────────────────┤
│ LocalAPIServer (127.0.0.1:19847)            │
├─────────────────────────────────────────────┤
│ KeychainHelper · ConfigLoader · LaunchAtLogin│
└─────────────────────────────────────────────┘
```

## Vibe Coded

This entire app was vibe coded — not a single line was written by a human. Built entirely through conversation with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using [pi](https://github.com/nickarrow/pi-coding-agent).

## License

MIT

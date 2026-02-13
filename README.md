# Clockoo

⏱️ A lightweight macOS menu bar app for Odoo time tracking.

No Electron. No browser. Native Swift. ~10-20 MB memory.

Part of the Odoo tooling family: [vodoo](https://github.com/julian-r/vodoo) (CLI) · [ghoodoo](https://github.com/julian-r/ghoodoo) (GitHub sync) · **clockoo** (time tracking)

## Features

- 🕐 **Menu bar icon** with live elapsed time when a timer is running
- 📋 **Popover** showing today's timesheets grouped by account
- 🔍 **Search** — find tasks, tickets, and recent timesheets to start a timer on
- ▶️ **Start / Stop** timers with a click (matches Odoo's task UI)
- 🗑️ **Delete** timesheet entries (workaround for server-side minimum duration)
- 🔗 **Open in browser** — jump to the task or ticket in Odoo
- 👥 **Multi-account** — multiple Odoo instances side by side
- 🔐 **Keychain storage** — API keys never touch config files
- 🎛️ **Stream Deck API** — local HTTP server on port 19847
- ⚡ **Optimistic UI** — actions feel instant, server confirms in background
- 🔔 **Blink when idle** — orange pulsing icon when no timer is running
- 🚀 **Launch at login** via LaunchAgent
- 🌐 **Dual API support** — JSON-2 (Odoo 19+) and legacy JSON-RPC (Odoo 14-18)
- 📦 **Zero dependencies** — pure Swift, AppKit + SwiftUI

## Setup

### 1. Build

```bash
./build.sh
# or manually:
swift build && codesign --force --sign - .build/debug/Clockoo
```

> Ad-hoc codesigning is required to avoid Keychain password prompts on every launch.

### 2. Configure

Create `~/.config/clockoo/accounts.json`:

```json
{
    "accounts": [
        {
            "id": "work",
            "label": "Work",
            "url": "https://mycompany.odoo.com",
            "database": "mycompany",
            "username": "user@example.com",
            "apiVersion": "json2"
        }
    ],
    "blinkWhenIdle": true
}
```

| Field | Description |
|-------|-------------|
| `id` | Unique identifier, used as Keychain account name |
| `label` | Display name in the UI |
| `url` | Odoo instance URL |
| `database` | Database name |
| `username` | Login email |
| `apiVersion` | `"json2"` (Odoo 19+) or `"legacy"` (Odoo 14-18) |

### 3. Add API Key

Via the **Settings** window (recommended), or manually:

```bash
security add-generic-password -s "com.clockoo" -a "work" -w "your-odoo-api-key"
```

Generate an API key in Odoo: *Preferences → Account Security → API Keys → New API Key*.

### 4. Run

```bash
.build/debug/Clockoo
```

The clock icon appears in the menu bar. Click it to see your timesheets and search for tasks.

## Settings

Open Settings from the popover's gear icon. Configure:

- **Accounts** — add, edit, test connection, set API version
- **General** — launch at login, blink when idle

## Stream Deck API

Local HTTP server on `http://localhost:19847`:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/timers` | GET | List all timesheets with state and elapsed time |
| `/api/accounts` | GET | List configured accounts |
| `/api/timers/{id}/toggle` | POST | Start or stop a timer |
| `/api/timers/{id}/start` | POST | Start a timer |
| `/api/timers/{id}/stop` | POST | Stop a timer |
| `/api/timers/{id}/delete` | POST | Delete a timesheet entry |

Timer IDs are in the format `accountId:timesheetId`.

## Search

The search bar in the popover searches across all accounts in parallel:

- **Tasks** — Odoo's `name_search` on `project.task` (fast, same as web UI autocomplete)
- **Tickets** — `name_search` on `helpdesk.ticket` (requires `helpdesk_timesheet` module)
- **Recent** — your timesheets from the last 7 days, deduped by task/ticket

Click ▶ to start a timer. For tasks and tickets, this creates a new timesheet and starts the timer automatically.

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
│ LocalAPIServer (NWListener, port 19847)     │
├─────────────────────────────────────────────┤
│ KeychainHelper (Security.framework)         │
│ ConfigLoader (~/.config/clockoo/)           │
│ LaunchAtLogin (~/Library/LaunchAgents/)     │
└─────────────────────────────────────────────┘
```

## Concept

See [docs/CONCEPT.md](docs/CONCEPT.md) for the full design document.

## License

MIT

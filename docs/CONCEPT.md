# Clockoo – Concept

## Vision

A lightweight macOS menu bar app that shows active Odoo timesheets/timers and lets you start, stop, and switch timers with a click. Multi-account support. Stream Deck integration. No Electron, no browser, no gigabytes of RAM.

## Tech Stack

| Choice | Why |
|--------|-----|
| **Swift + AppKit** | Native macOS menu bar app. ~10-20 MB memory. First-class system tray support. |
| **JSON-RPC over URLSession** | Odoo's `/jsonrpc` endpoint. Swift has first-class JSON support (`Codable`, `JSONEncoder`/`JSONDecoder`). ~50-80 lines for the client, no dependencies needed. |
| **SwiftUI popover** | For the timer list UI inside the menu bar popover. Lightweight, native, no web views. |
| **Local HTTP API** | Tiny local server for Stream Deck plugin and other integrations. |
| **Stream Deck plugin (Node.js/TS)** | Thin client using Elgato's official SDK, talks to clockoo's local API. |

### Why JSON-RPC instead of XML-RPC?

Vodoo uses XML-RPC (Python has it built-in). In Swift, JSON is the native format — `Codable` structs decode directly from JSON-RPC responses with zero manual parsing. Odoo supports both protocols equally.

```
POST https://mycompany.odoo.com/jsonrpc
Content-Type: application/json

{
    "jsonrpc": "2.0",
    "method": "call",
    "params": {
        "service": "object",
        "method": "execute_kw",
        "args": ["db", uid, "password", "account.analytic.line", "search_read",
                 [[["user_id", "=", uid], ["timer_start", "!=", false]]],
                 {"fields": ["name", "project_id", "task_id", "timer_start", "timer_pause"]}]
    }
}
```

## Multi-Account Support

Clockoo supports multiple Odoo instances from the start. Each account is a separate connection with its own credentials and polling cycle.

### Config: `~/.config/clockoo/accounts.json`

```json
{
    "accounts": [
        {
            "id": "work",
            "label": "Work",
            "url": "https://work.odoo.com",
            "database": "work-db",
            "username": "user@work.com",
            "apiKey": "keychain:clockoo/work"
        },
        {
            "id": "freelance",
            "label": "Freelance",
            "url": "https://freelance.odoo.com",
            "database": "freelance-db",
            "username": "user@freelance.com",
            "apiKey": "keychain:clockoo/freelance"
        }
    ]
}
```

### Design Decisions

- **Secrets in macOS Keychain** — API keys stored in Keychain, referenced via `keychain:` prefix. Never in plaintext config files.
- **Backward-compatible with vodoo** — If no `accounts.json` exists, clockoo falls back to reading `~/.config/vodoo/config.env` as a single account.
- **Account label in UI** — Each timer row shows which account it belongs to (subtle badge/color).
- **Independent polling** — Each account has its own poll cycle. One slow/down instance doesn't block others.
- **Per-account timer state** — Each Odoo instance can have its own running timer (they're independent systems).

### Popover with Multi-Account

```
┌──────────────────────────────────────────┐
│  Work                                    │  ← account header
│  ▶ 🔧 ODP-142 Fix login bug       1:23  │  ← running (green accent)
│  ⏸ 🎫 TKT-89  Printer issue       0:45  │  ← paused
│──────────────────────────────────────────│
│  Freelance                               │  ← account header
│  ■ 🔧 PRJ-12  Landing page        2:10  │  ← stopped
│──────────────────────────────────────────│
│  ⏱ Start new timer...                   │
│  ──────────────────────────────────────  │
│  ⚙ Settings              ⏻ Quit        │
└──────────────────────────────────────────┘
```

If only one account is configured, account headers are hidden.

## Odoo Models

### Timesheets: `account.analytic.line`

The core model for time tracking in Odoo. **All timers** — whether started from a project task or a helpdesk ticket — create entries here. Key fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | int | Record ID |
| `name` | str | Description |
| `project_id` | many2one | Project reference |
| `task_id` | many2one | Task reference (project tasks) |
| `helpdesk_ticket_id` | many2one | Helpdesk ticket reference |
| `unit_amount` | float | Duration in hours |
| `date` | date | Timesheet date |
| `user_id` | many2one | Assigned user |
| `timer_start` | datetime | When the timer was started (if running) |
| `timer_pause` | datetime | When the timer was paused |

### Timer Sources

Timers can originate from three places in Odoo:

| Source | Model | Timesheet link field |
|--------|-------|---------------------|
| **Project Task** | `project.task` | `task_id` |
| **Helpdesk Ticket** | `helpdesk.ticket` | `helpdesk_ticket_id` |
| **Standalone** | (direct timesheet) | neither |

Clockoo queries `account.analytic.line` to get **all** active timers regardless of source, and displays the origin (task name, ticket name, or project name) for context.

### Timer Detection

A timer is **running** when `timer_start` is set and `timer_pause` is **not** set.  
A timer is **paused** when both `timer_start` and `timer_pause` are set.

Query for active timers:
```
domain: [
    ("user_id", "=", uid),
    ("timer_start", "!=", False),
    ("date", "=", today)
]
fields: [
    "name", "project_id", "task_id", "helpdesk_ticket_id",
    "unit_amount", "timer_start", "timer_pause", "date"
]
```

### Timer Actions

Odoo exposes timer methods on `account.analytic.line`:
- `action_timer_start` – Start/resume a timer
- `action_timer_stop` – Stop a timer (calculates `unit_amount`)
- `action_timer_pause` – Pause a running timer
- `action_timer_resume` – Resume a paused timer

These can be called via JSON-RPC:
```json
{
    "jsonrpc": "2.0",
    "method": "call",
    "params": {
        "service": "object",
        "method": "execute_kw",
        "args": ["db", 2, "api-key", "account.analytic.line", "action_timer_start", [[42]]]
    }
}
```

### Opening in Odoo Web

Right-click / secondary action should open the **source record** (not the timesheet line):
- If `task_id` is set → open `project.task` form
- If `helpdesk_ticket_id` is set → open `helpdesk.ticket` form
- Otherwise → open `account.analytic.line` form

## UI Design

### Menu Bar Icon

- **No timer running:** 🕐 Clock icon (outline/grey)
- **Timer running:** 🕐 Clock icon (filled/accent color) + elapsed time as text `1:23`
- Optional: Pulsing dot or color accent to make running state obvious at a glance
- Multi-account: shows the first running timer's elapsed time (or the most recently active)

### Click → Popover

See [Multi-Account Popover](#popover-with-multi-account) above.

- Click on a paused timer → resumes it (and pauses the currently running one — Odoo only allows one active timer per user per instance)
- Click stop on running timer → stops it
- Right-click / secondary action → open in Odoo web

### Visual Running Indicator

- The menu bar shows elapsed time updating every minute (or every 30s)
- Running timer row has a green left border / accent
- Paused timer rows are dimmed
- Menu bar icon changes color/style when a timer is active

## Stream Deck Integration

### Architecture

```
┌─────────────┐    HTTP/localhost    ┌──────────────┐    JSON-RPC    ┌──────┐
│  Stream Deck │ ◄─────────────────► │   Clockoo    │ ◄────────────► │ Odoo │
│   Plugin     │    :19847           │  (menu bar)  │               │      │
│  (Node.js)   │                     └──────────────┘               └──────┘
└─────────────┘
```

Clockoo runs a **tiny local HTTP server** (port 19847 or configurable) that the Stream Deck plugin calls. This keeps all Odoo logic and credentials in clockoo — the Stream Deck plugin is a thin UI layer.

### Local API Endpoints

```
GET  /api/timers                    → list all active timers (all accounts)
POST /api/timers/:id/start          → start/resume a timer
POST /api/timers/:id/stop           → stop a timer
POST /api/timers/:id/pause          → pause a timer
POST /api/timers/:id/toggle         → toggle running/paused (for one-button control)
GET  /api/accounts                  → list configured accounts
```

Timer IDs in the API are prefixed with account ID: `work:42`, `freelance:17`.

### Stream Deck Plugin

Built with the official Elgato Stream Deck SDK (Node.js/TypeScript).

**Actions:**

| Action | Button | Description |
|--------|--------|-------------|
| **Toggle Timer** | Single key | Shows timer name + elapsed time on the key. Press to toggle start/pause. Long press to stop. |
| **Quick Switch** | Single key | Assign a specific task/ticket. Press to start that timer (pauses current). |
| **Timer Status** | Display key | Shows current running timer info, no action on press. |

**Key display updates** via polling clockoo's local API every 5s.

**Property Inspector** (Stream Deck settings UI):
- Select account
- Browse/search tasks and tickets to bind to a key
- Configure display format

### Plugin Structure

```
clockoo-streamdeck/
├── com.clockoo.sdPlugin/
│   ├── manifest.json
│   ├── imgs/
│   └── ui/
│       └── property-inspector.html
├── src/
│   ├── plugin.ts
│   └── actions/
│       ├── toggle-timer.ts
│       ├── quick-switch.ts
│       └── timer-status.ts
├── package.json
├── rollup.config.mjs
└── tsconfig.json
```

This lives in a `streamdeck/` subdirectory of the clockoo repo (or a separate repo if it grows).

## Configuration

### Primary: `~/.config/clockoo/accounts.json`

See [Multi-Account Support](#multi-account-support) above.

### Fallback: `~/.config/vodoo/config.env`

If no clockoo config exists, reads vodoo's config as a single account for easy onboarding.

### Settings stored in clockoo

- Poll interval (default 60s)
- Local API port (default 19847)
- Show elapsed time in menu bar (on/off)
- Launch at login (on/off)

## Polling Strategy

- Poll each Odoo account every **60 seconds** for active timers
- Update elapsed time display locally between polls (simple local clock math from `timer_start`)
- On user action (start/stop/pause) → immediate API call + refresh
- Stream Deck plugin polls clockoo's local API every **5 seconds** (local, negligible cost)

## Project Structure

```
clockoo/
├── Clockoo/
│   ├── ClockooApp.swift            # App entry point, menu bar setup
│   ├── MenuBarController.swift     # NSStatusItem, icon, elapsed time
│   ├── TimerPopover.swift          # SwiftUI popover with timer list
│   ├── Odoo/
│   │   ├── OdooJSONRPCClient.swift # JSON-RPC client via URLSession
│   │   └── OdooTimerService.swift  # Fetch/start/stop/pause timers
│   ├── Accounts/
│   │   ├── AccountManager.swift    # Multi-account lifecycle
│   │   ├── AccountConfig.swift     # Account model + JSON parsing
│   │   └── KeychainHelper.swift    # macOS Keychain access
│   ├── LocalAPI/
│   │   └── LocalAPIServer.swift    # HTTP server for Stream Deck
│   └── Models/
│       └── Timesheet.swift         # Timesheet data model
├── Clockoo.xcodeproj/
├── streamdeck/                     # Stream Deck plugin (Node.js/TS)
│   ├── com.clockoo.sdPlugin/
│   ├── src/
│   ├── package.json
│   └── tsconfig.json
├── docs/
│   └── CONCEPT.md
├── README.md
├── LICENSE
└── .gitignore
```

## MVP Scope

1. ✅ Multi-account config (`accounts.json` + vodoo fallback)
2. ✅ Keychain storage for API keys
3. ✅ Connect to Odoo via JSON-RPC, authenticate
4. ✅ Fetch today's timesheets for current user (tasks + tickets + standalone)
5. ✅ Show in menu bar: icon + elapsed time if running
6. ✅ Popover: list timers grouped by account with status (running/paused/stopped)
7. ✅ Click to start/stop/pause/resume timers
8. ✅ Visual distinction: running vs paused vs stopped
9. ✅ Poll every 60s, local clock updates between polls
10. ✅ Local HTTP API for integrations

## Post-MVP

- Stream Deck plugin (toggle, quick-switch, status actions)
- Keyboard shortcut to toggle current timer
- Notification when timer has been running > X hours
- Quick-start from recent tasks (search in popover)
- Weekly summary view
- Launch at login

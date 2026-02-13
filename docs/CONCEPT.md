# Clockoo – Concept

## Vision

A lightweight macOS menu bar app that shows active Odoo timesheets/timers and lets you start, stop, and switch timers with a click. No Electron, no browser, no gigabytes of RAM.

## Tech Stack

| Choice | Why |
|--------|-----|
| **Swift + AppKit** | Native macOS menu bar app. ~10-20 MB memory. First-class system tray support. |
| **XML-RPC** | Same Odoo API as vodoo. Proven, well-understood. Swift has Foundation's `XMLParser` + we can use a lightweight XML-RPC lib or roll a minimal one. |
| **SwiftUI popover** | For the timer list UI inside the menu bar popover. Lightweight, native, no web views. |

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

These can be called via XML-RPC:
```
execute_kw(db, uid, password, "account.analytic.line", "action_timer_start", [[line_id]])
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

### Click → Popover

```
┌──────────────────────────────────────┐
│  ▶ 🔧 ODP-142 Fix login bug   1:23  │  ← running task (green accent)
│  ⏸ 🎫 TKT-89 Printer issue   0:45  │  ← paused ticket (dimmed)
│  ■ 🔧 ODP-201 Deploy staging  2:10  │  ← stopped task
│──────────────────────────────────────│
│  ⏱ Start new timer...               │
│  ──────────────────────────────────  │
│  ⚙ Settings          ⏻ Quit        │
└──────────────────────────────────────┘
```

- Click on a paused timer → resumes it (and pauses the currently running one, Odoo only allows one active timer)
- Click stop on running timer → stops it
- Right-click / secondary action → open in Odoo web

### Visual Running Indicator

- The menu bar shows elapsed time updating every minute (or every 30s)
- Running timer row has a green left border / accent
- Paused timer rows are dimmed
- Menu bar icon changes color/style when a timer is active

## Configuration

Reuse vodoo's config file at `~/.config/vodoo/config.env`:

```
ODOO_URL=https://mycompany.odoo.com
ODOO_DATABASE=mycompany
ODOO_USERNAME=user@example.com
ODOO_PASSWORD=api-key-here
```

Clockoo reads the same file. No duplicate config needed.

## Polling Strategy

- Poll Odoo every **60 seconds** for active timers
- Update elapsed time display locally between polls (simple local clock math from `timer_start`)
- On user action (start/stop/pause) → immediate API call + refresh

## Project Structure

```
clockoo/
├── Clockoo/
│   ├── ClockooApp.swift          # App entry point, menu bar setup
│   ├── MenuBarController.swift   # NSStatusItem, icon, elapsed time
│   ├── TimerPopover.swift        # SwiftUI popover with timer list
│   ├── OdooClient.swift          # XML-RPC client (mirrors vodoo's client.py)
│   ├── TimesheetService.swift    # Fetch/start/stop/pause timers
│   ├── Config.swift              # Read vodoo config file
│   └── Models/
│       ├── Timesheet.swift       # Timesheet data model
│       └── OdooConfig.swift      # Config data model
├── Clockoo.xcodeproj/
├── docs/
│   └── CONCEPT.md
├── README.md
├── LICENSE
└── .gitignore
```

## MVP Scope

1. ✅ Read config from `~/.config/vodoo/config.env`
2. ✅ Connect to Odoo via XML-RPC, authenticate
3. ✅ Fetch today's timesheets for current user
4. ✅ Show in menu bar: icon + elapsed time if running
5. ✅ Popover: list timers with status (running/paused/stopped)
6. ✅ Click to start/stop/pause/resume timers
7. ✅ Visual distinction: running vs paused vs stopped
8. ✅ Poll every 60s, local clock updates between polls

## Future Ideas

- Keyboard shortcut to toggle current timer
- Notification when timer has been running > X hours
- Quick-start from recent tasks
- Integration with vodoo CLI (share more than just config)
- Task search in popover to start new timesheets
- Weekly summary view

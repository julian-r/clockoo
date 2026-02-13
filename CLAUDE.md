# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Clockoo is a lightweight macOS menu bar app for Odoo time tracking. Native Swift, no Electron. Shows active timers from project tasks and helpdesk tickets.

Part of the Odoo tooling family: vodoo (CLI) · ghoodoo (GitHub sync) · clockoo (time tracking)

## Commands

```bash
# Build
swift build

# Run
swift run Clockoo

# Build release
swift build -c release
```

## Architecture

### Tech Stack
- **Swift + AppKit + SwiftUI** — native macOS menu bar app
- **JSON-RPC over URLSession** — Odoo `/jsonrpc` endpoint, no XML-RPC
- **Network framework** — local HTTP API server for Stream Deck integration
- **Security framework** — macOS Keychain for API key storage
- **Zero external dependencies**

### Module Structure

- **ClockooApp.swift** — App entry point, NSApplication setup (menu bar only, no dock icon)
- **Accounts/**
  - `AccountConfig.swift` — Config model, loads `~/.config/clockoo/accounts.json`
  - `AccountManager.swift` — Multi-account lifecycle, polling, timer actions
  - `KeychainHelper.swift` — macOS Keychain read/write for API keys (service: `com.clockoo`)
- **Odoo/**
  - `OdooJSONRPCClient.swift` — JSON-RPC transport layer for Odoo's `/jsonrpc` endpoint
  - `OdooTimerService.swift` — Fetch/start/stop/pause timers on `account.analytic.line`
- **UI/**
  - `MenuBarController.swift` — NSStatusItem management, icon + elapsed time display
  - `TimerPopover.swift` — SwiftUI popover with timer list, grouped by account
- **LocalAPI/**
  - `LocalAPIServer.swift` — HTTP server on port 19847 for Stream Deck plugin
- **Models/**
  - `Timesheet.swift` — Timesheet model with timer state, source (task/ticket/standalone)

### Configuration

- Accounts: `~/.config/clockoo/accounts.json` (no secrets — just URL, database, username)
- API keys: macOS Keychain (service: `com.clockoo`, account: the account ID)
- Sample config is auto-created on first run

### Odoo Integration

- Model: `account.analytic.line` (timesheets)
- Timer fields: `timer_start`, `timer_pause`
- Timer actions: `action_timer_start`, `action_timer_stop`, `action_timer_pause`, `action_timer_resume`
- Sources: `task_id` (project tasks), `helpdesk_ticket_id` (helpdesk tickets)
- API: Odoo JSON-RPC at `/jsonrpc` endpoint

### Local API (for Stream Deck)

- `GET /api/timers` — all active timers
- `POST /api/timers/:accountId\::id/start|stop|pause|toggle` — timer actions
- `GET /api/accounts` — configured accounts

## Design Principles

- No external dependencies — everything uses Apple frameworks
- Memory-efficient — native app, no web views, no Electron
- Multi-account from the start — each account polls independently
- Secrets in Keychain only — never in config files

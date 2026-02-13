# Clockoo

⏱️ A lightweight macOS menu bar app for Odoo time tracking.

No Electron. No browser. Native Swift. ~10-20 MB memory.

Shows your active timers from project tasks and helpdesk tickets. Start, stop, pause with a click.

Part of the Odoo tooling family: [vodoo](https://github.com/julian-r/vodoo) (CLI) · [ghoodoo](https://github.com/julian-r/ghoodoo) (GitHub sync) · **clockoo** (time tracking)

## Features

- 🕐 Menu bar icon with live elapsed time when a timer is running
- 📋 Popover showing all active timers (tasks + tickets)
- ▶️ Start / ⏸ Pause / ■ Stop timers with a click
- 👥 Multi-account support (multiple Odoo instances)
- 🔐 API keys stored in macOS Keychain (never in config files)
- 🎛️ Local HTTP API for Stream Deck and other integrations
- 📦 Zero external dependencies

## Setup

### 1. Build

```bash
swift build -c release
```

### 2. Configure

Edit `~/.config/clockoo/accounts.json` (created on first run):

```json
{
    "accounts": [
        {
            "id": "work",
            "label": "Work",
            "url": "https://mycompany.odoo.com",
            "database": "mycompany",
            "username": "user@example.com"
        }
    ]
}
```

### 3. Add API Key to Keychain

```bash
security add-generic-password -s "com.clockoo" -a "work" -w "your-odoo-api-key"
```

### 4. Run

```bash
swift run Clockoo
# or
.build/release/Clockoo
```

## Concept

See [docs/CONCEPT.md](docs/CONCEPT.md) for the full design.

## License

MIT

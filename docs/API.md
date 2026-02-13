# Clockoo Local API

Clockoo runs a local HTTP server on `http://127.0.0.1:19847` for integration with Stream Deck, Hammerspoon, shell scripts, and other tools.

> **Security**: The server binds to `127.0.0.1` (localhost only) and is not accessible from the network. No authentication is required since only local processes can connect.

## Endpoints

### List Timesheets

```
GET /api/timers
```

Returns today's timesheets across all accounts.

**Response:**
```json
[
  {
    "id": "work:42",
    "name": "Implement feature X",
    "displayLabel": "🔧 Implement feature X",
    "projectName": "Software Development",
    "accountId": "work",
    "state": "running",
    "elapsed": "1:23",
    "elapsedSeconds": "4980"
  }
]
```

### List Accounts

```
GET /api/accounts
```

**Response:**
```json
[
  {
    "id": "work",
    "label": "Work",
    "url": "https://mycompany.odoo.com"
  }
]
```

### Toggle Timer (Start/Stop)

```
POST /api/timers/{id}/toggle
```

Starts a stopped timer or stops a running timer.

### Start Timer

```
POST /api/timers/{id}/start
```

### Stop Timer

```
POST /api/timers/{id}/stop
```

### Delete Timesheet

```
POST /api/timers/{id}/delete
```

Permanently deletes the timesheet entry from Odoo.

## Timer IDs

Timer IDs are in the format `accountId:timesheetId`, e.g. `work:42`. Use the IDs from the `GET /api/timers` response.

## Examples

### curl

```bash
# List all timers
curl http://127.0.0.1:19847/api/timers

# Toggle the first running timer
curl -X POST http://127.0.0.1:19847/api/timers/work:42/toggle

# Stop a specific timer
curl -X POST http://127.0.0.1:19847/api/timers/work:42/stop
```

### Stream Deck (via shell action)

```bash
#!/bin/bash
# Toggle the most recent timer
ID=$(curl -s http://127.0.0.1:19847/api/timers | python3 -c "import sys,json; t=json.load(sys.stdin); print(t[0]['id'] if t else '')")
[ -n "$ID" ] && curl -s -X POST "http://127.0.0.1:19847/api/timers/$ID/toggle"
```

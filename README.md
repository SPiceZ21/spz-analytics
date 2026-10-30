# spz-analytics

> Analytics collector for Grafana.

![version](https://img.shields.io/badge/version-1.2.0-ff6200) ![SPiceZ-Core](https://img.shields.io/badge/SPiceZ--Core-beta-18181b)

## Overview

Writes sessions, activity per mode, the race funnel, laps, vehicle and feature usage, daily stats and per-minute server snapshots to the database in batches, ready for Grafana dashboards.

## Features

- Batched writes
- Per-minute server snapshots
- Race funnel and feature usage

## Requirements

| Resource | Type |
|---|---|
| `oxmysql` | third-party |
| `spz-core` | SPiceZ module |

## Installation

Included in the [txAdmin recipe](https://github.com/SPiceZ21/spz-txrecipe). Manual install:

1. Download `spz-analytics` from GitHub (latest release, or the repository) into your `resources` folder.
2. Add to `server.cfg`, after its requirements:

```cfg
ensure spz-analytics
```

## Configuration

- `config.lua`

See the file for every option.

## Exports

| Export | Side |
|---|---|
| `AdminAction` | server |
| `Event` | server |
| `Reject` | server |
| `Track` | server |

```lua
exports["spz-analytics"]:AdminAction(...)
```

---

Part of **SPiceZ-Core** — [documentation](https://github.com/SPiceZ21/Docs) · [all modules](https://github.com/SPiceZ21/Docs/blob/main/modules/README.md)

-- config.lua — spz-analytics
-- Data only; Grafana reads the tables (read-only account). Schema lives in
-- spz-core/migrations/analytics/ (022-029).

Config = {}

Config.TickSec       = 5     -- player state / vehicle sampling
Config.LapSampleMs   = 1000  -- racer speed sampling for race_laps top/avg
Config.SnapshotSec   = 60    -- server_snapshots row
Config.FlushSec      = 30    -- batched DB writes
Config.RetentionDays = 90    -- raw rows older than this are deleted nightly
                             -- (sessions, activity, queue events, laps, engine events, connections,
                             -- snapshots, vehicle usage). Daily stats and
                             -- feature counts, race entries, rating history, server events, admin
                             -- actions and credit balances are kept forever.
Config.MinStintSec   = 10    -- shorter vehicle stints are not stored

-- inMinigame values (set by each minigame on the player) → activity mode.
-- Anything else that is truthy is stored as "minigame".
Config.MinigameModes = {
    ["Hot Pursuit"] = "pursuit",
    ["Hide & Seek"] = "hideseek",
    ["Color Rush"]  = "colorrush",
    ["replay"]      = "replay",
}

-- Features clients may report (spz-analytics:feature). Anything not listed is
-- ignored, so a client can't fill feature_usage with junk.
Config.Features = {
    leaderboard_open = true,
    replays_browser  = true,
    replay_watch     = true,
    admin_race       = true,
    spectate         = true,
    timetrial        = true,
}

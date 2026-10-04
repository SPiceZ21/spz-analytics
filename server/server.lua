-- server/server.lua — the server around the players.
--
--   connection_attempts    joined (with load time) / rejected (with reason) /
--                          abandoned (never made it in)
--   server_events          server boot, resource starts and stops
--   admin_actions          export AdminAction, called by spz-admin,
--                          spz-discord (/adminmode), /srace, replay deletes
--   daily_credit_balances  hourly upsert of today's balances for recently
--                          active players (the last run of the day stands)
-- Entity counts ride on server_snapshots (server/main.lua).

local A = Analytics
local BOOT_GRACE_MS = 5 * 60 * 1000   -- resource starts during boot aren't logged one by one

local function license(src)
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if id:sub(1, 8) == "license:" then return id end
    end
end

-- Player id for a license, looked up when the row is written.
local function insertConnection(lic, outcome, reason, waitMs, loadMs)
    CreateThread(function()
        local pid = nil
        if lic then
            local ok, id = pcall(function()
                return MySQL.scalar.await("SELECT id FROM players WHERE identifier = ? LIMIT 1", { lic })
            end)
            pid = ok and tonumber(id) or nil
        end
        DB.Insert("connection_attempts", { "player_id", "outcome", "reason", "wait_ms", "load_ms", "created_at" },
            { pid, outcome, reason and tostring(reason):sub(1, 160) or nil,
              waitMs and math.floor(waitMs) or nil, loadMs and math.floor(loadMs) or nil, DB.Now() })
    end)
end

-- ── Connections ──────────────────────────────────────────────────────────────

local connecting = {}   -- [tempId] = { t, lic, rejected }
local loading = {}      -- [src]    = { t, joinedAt, lic }

AddEventHandler("playerConnecting", function()
    local src = source
    connecting[src] = { t = GetGameTimer(), lic = license(src) }
end)

--- Called by whatever turns a player away during connecting:
---   exports["spz-analytics"]:Reject(source, "Join our Discord server ...")
exports("Reject", function(tempSrc, reason)
    tempSrc = tonumber(tempSrc)
    local c = connecting[tempSrc]
    if not c then c = { t = GetGameTimer(), lic = tempSrc and license(tempSrc) }; connecting[tempSrc] = c end
    if c.rejected then return end
    c.rejected = true
    insertConnection(c.lic, "rejected", reason, GetGameTimer() - c.t, nil)
end)

AddEventHandler("playerJoining", function(oldId)
    local src = source
    local c = connecting[tonumber(oldId)]
    connecting[tonumber(oldId)] = nil
    loading[src] = { t = c and c.t or GetGameTimer(), joinedAt = GetGameTimer(), lic = (c and c.lic) or license(src) }
end)

-- The client says so once it's actually in the world (screen faded in).
RegisterNetEvent("spz-analytics:spawned", function()
    local src = source
    local l = loading[src]
    if not l then return end
    loading[src] = nil
    insertConnection(l.lic, "joined", nil, l.joinedAt - l.t, GetGameTimer() - l.t)
end)

AddEventHandler("playerDropped", function(reason)
    local src = source
    local l = loading[src]
    if l then
        loading[src] = nil
        insertConnection(l.lic, "abandoned", reason or "dropped while loading", l.joinedAt - l.t, nil)
    end
end)

-- Connecting entries that never joined and were never rejected.
CreateThread(function()
    while true do
        Wait(60000)
        local now = GetGameTimer()
        for id, c in pairs(connecting) do
            if now - c.t > 5 * 60000 then
                connecting[id] = nil
                if not c.rejected then insertConnection(c.lic, "abandoned", "never finished connecting", now - c.t, nil) end
            end
        end
    end
end)

-- ── Server lifecycle ─────────────────────────────────────────────────────────

local function serverEvent(event, detail)
    DB.Insert("server_events", { "event", "detail", "uptime_s", "players", "created_at" },
        { event, detail and tostring(detail):sub(1, 128) or nil, math.floor(GetGameTimer() / 1000),
          #GetPlayers(), DB.Now() })
end

CreateThread(function()
    if GetGameTimer() < BOOT_GRACE_MS then serverEvent("server_start") end
end)

AddEventHandler("onResourceStart", function(res)
    if res == GetCurrentResourceName() or GetGameTimer() < BOOT_GRACE_MS then return end
    serverEvent("resource_start", res)
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() then
        serverEvent("analytics_stop")
        return   -- main.lua's stop handler flushes
    end
    serverEvent("resource_stop", res)
end)

-- ── Admin actions ────────────────────────────────────────────────────────────

--- exports["spz-analytics"]:AdminAction(adminSrc, "kick", "SomePlayer (12): reason")
exports("AdminAction", function(src, action, detail)
    if type(action) ~= "string" then return end
    src = tonumber(src)
    DB.Insert("admin_actions", { "admin_id", "admin_name", "action", "detail", "created_at" },
        { src and src > 0 and A.profileId(src) or nil,
          src and src > 0 and (GetPlayerName(src) or ""):sub(1, 64) or "console",
          action:sub(1, 64), detail and tostring(detail):sub(1, 255) or nil, DB.Now() })
end)

-- ── Daily credit balances ────────────────────────────────────────────────────

CreateThread(function()
    Wait(90000)   -- after migrations and the first flush
    while true do
        pcall(function()
            MySQL.query.await([[
                INSERT INTO daily_credit_balances (day, player_id, credits)
                SELECT CURDATE(), p.id, COALESCE(p.credits, 0) FROM players p
                WHERE p.id IN (SELECT DISTINCT player_id FROM daily_player_stats
                               WHERE day >= CURDATE() - INTERVAL 30 DAY)
                ON DUPLICATE KEY UPDATE credits = VALUES(credits)
            ]])
        end)
        Wait(3600000)
    end
end)

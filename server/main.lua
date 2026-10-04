-- server/main.lua — what spz-analytics collects, and when.
--
-- Everything is derived from state the server already has (player statebags,
-- spz-races results, ped/vehicle entities) plus one small client report (the
-- minigame the player is in, which minigames only set client-side). Rows go
-- through server/db.lua in batches.
--
--   player_sessions     on disconnect (or resource stop)
--   player_activity     whenever a player's mode changes
--   race_queue_events   queue join/leave, race start, finish, DNF
--   race_laps           every lap of every finisher, with sampled speeds
--   server_snapshots    once a minute
--   vehicle_usage       when a driving stint ends
--   feature_usage       daily counters (export Track / client event)
--   daily_player_stats  daily counters

local P = {}            -- [src] = per-player tracking
local clientMode = {}   -- [src] = minigame mode reported by the client
local ready = false

local function profileId(src)
    local prof = Player(src).state.profile
    return type(prof) == "table" and tonumber(prof.id) or nil
end

local function isTT(src)
    if GetResourceState("spz-races") ~= "started" then return false end
    local ok, v = pcall(function() return exports["spz-races"]:IsInTimeTrial(src) end)
    return ok and v == true
end

local function isSpectating(src)
    if GetResourceState("spz-spectate") ~= "started" then return false end
    local ok, v = pcall(function() return exports["spz-spectate"]:IsSpectating(src) end)
    return ok and v == true
end

local function modeOf(src)
    local st = Player(src).state
    if st.inRace then return "race" end
    if st.inQueue then return "queue" end
    if isTT(src) then return "timetrial" end
    if isSpectating(src) then return "spectate" end
    if st.inMinigame == "replay" then return "replay" end
    if clientMode[src] then return clientMode[src] end
    return "freeroam"
end

local function daily(pid, sums)
    if pid then DB.Add("daily_player_stats", { "day", "player_id" }, { DB.Day(), pid }, sums) end
end

local function raceId()
    if GetResourceState("spz-races") ~= "started" then return nil end
    local ok, info = pcall(function() return exports["spz-races"]:GetRaceInfo() end)
    return ok and info and info.raceId or nil
end

-- ── Per-player lifecycle ─────────────────────────────────────────────────────

local function track(src)
    if P[src] then return P[src] end
    local now = os.time()
    P[src] = {
        joined = now, joinedStr = DB.Now(),
        pingSum = 0, pingN = 0, pingMax = 0,
        mode = nil, modeSince = now, modeSinceStr = DB.Now(),
        inQueue = false, inRace = false,
        stint = nil, laps = {},
        counted = false,
    }
    return P[src]
end

local function closeActivity(src, p, nowStr, now)
    if not p.mode then return end
    local dur = now - p.modeSince
    if dur >= 1 then
        DB.Insert("player_activity", { "player_id", "mode", "started_at", "ended_at", "duration_s" },
            { profileId(src) or p.pid, p.mode, p.modeSinceStr, nowStr, dur })
    end
end

local function closeStint(src, p, nowStr)
    local s = p.stint
    if not s then return end
    p.stint = nil
    if s.secs >= Config.MinStintSec then
        DB.Insert("vehicle_usage", { "player_id", "model", "mode", "started_at", "ended_at", "seconds", "distance_m" },
            { profileId(src) or p.pid, s.model, s.mode, s.sinceStr, nowStr, s.secs, math.floor(s.dist) })
    end
end

local function untrack(src, reason)
    local p = P[src]
    if not p then return end
    P[src] = nil
    clientMode[src] = nil
    local now, nowStr = os.time(), DB.Now()
    closeActivity(src, p, nowStr, now)
    closeStint(src, p, nowStr)
    DB.Insert("player_sessions",
        { "player_id", "started_at", "ended_at", "duration_s", "disconnect_reason", "avg_ping", "max_ping", "first_session" },
        { p.pid, p.joinedStr, nowStr, now - p.joined, reason and tostring(reason):sub(1, 128) or nil,
          p.pingN > 0 and math.floor(p.pingSum / p.pingN) or nil, p.pingN > 0 and p.pingMax or nil,
          p.first and 1 or 0 })
end

AddEventHandler("playerJoining", function() track(source) end)
AddEventHandler("playerDropped", function(reason) untrack(source, reason) end)

-- ── Client reports ───────────────────────────────────────────────────────────

RegisterNetEvent("spz-analytics:mode", function(value)
    local src = source
    if type(value) ~= "string" or value == "" then clientMode[src] = nil; return end
    clientMode[src] = Config.MinigameModes[value:sub(1, 32)] or "minigame"
end)

local featureCooldown = {}   -- [src..feature] = ms
local function trackFeature(feature)
    if not Config.Features[feature] then return end
    DB.Add("feature_usage", { "day", "feature" }, { DB.Day(), feature }, { uses = 1 })
end
exports("Track", trackFeature)

RegisterNetEvent("spz-analytics:feature", function(feature)
    local src = source
    if type(feature) ~= "string" or not Config.Features[feature] then return end
    local k = src .. feature
    local now = GetGameTimer()
    if featureCooldown[k] and now - featureCooldown[k] < 2000 then return end
    featureCooldown[k] = now
    trackFeature(feature)
end)

-- ── Main tick: modes, funnel, vehicles, playtime, ping ───────────────────────

local function tickPlayer(src, now, nowStr)
    local p = track(src)
    local pid = profileId(src)
    if pid and not p.pid then
        p.pid = pid
        local prof = Player(src).state.profile
        p.first = type(prof) == "table" and (tonumber(prof.playtime) or 0) < 60
    end
    if p.pid and not p.counted then
        p.counted = true
        daily(p.pid, { sessions = 1 })
    end

    -- Ping
    local ping = GetPlayerPing(src) or 0
    if ping > 0 then
        p.pingSum, p.pingN = p.pingSum + ping, p.pingN + 1
        if ping > p.pingMax then p.pingMax = ping end
    end

    -- Mode / activity
    local mode = modeOf(src)
    if mode ~= p.mode then
        closeActivity(src, p, nowStr, now)
        p.mode, p.modeSince, p.modeSinceStr = mode, now, nowStr
    end
    daily(p.pid, { playtime_s = Config.TickSec })

    -- Race funnel
    local st = Player(src).state
    local inQ, inR = st.inQueue == true, st.inRace == true
    if inQ and not p.inQueue then
        DB.Insert("race_queue_events", { "race_id", "player_id", "event", "detail", "created_at" },
            { nil, p.pid, "queue_join", nil, nowStr })
    elseif p.inQueue and not inQ and not inR then
        DB.Insert("race_queue_events", { "race_id", "player_id", "event", "detail", "created_at" },
            { nil, p.pid, "queue_leave", nil, nowStr })
    end
    if inR and not p.inRace then
        DB.Insert("race_queue_events", { "race_id", "player_id", "event", "detail", "created_at" },
            { raceId(), p.pid, "race_start", nil, nowStr })
        daily(p.pid, { races = 1 })
        p.laps = {}
        if Analytics.OnRaceStart then Analytics.OnRaceStart(src, p) end
    end
    p.inQueue, p.inRace = inQ, inR

    -- Vehicle stint (as driver)
    local ped = GetPlayerPed(src)
    local veh = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
        local model
        if GetResourceState("spz-vehicles") == "started" then
            local ok, v = pcall(function() return exports["spz-vehicles"]:GetPlayerVehicle(src) end)
            if ok and v and v.entity == veh and v.model then model = tostring(v.model) end
        end
        model = model or tostring(GetEntityModel(veh))
        local pos = GetEntityCoords(veh)
        local s = p.stint
        if s and (s.model ~= model or s.mode ~= mode) then closeStint(src, p, nowStr); s = nil end
        if not s then
            p.stint = { model = model, mode = mode, sinceStr = nowStr, secs = 0, dist = 0, last = pos }
        else
            local d = #(pos - s.last)
            if d > Config.TickSec * 120 then d = 0 end      -- teleport / reset, not driving
            s.dist, s.secs, s.last = s.dist + d, s.secs + Config.TickSec, pos
            daily(p.pid, { distance_m = math.floor(d) })
        end
    elseif p.stint then
        closeStint(src, p, nowStr)
    end
end

-- ── Lap speed sampling (racers only) ─────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(Config.LapSampleMs)
        for src, p in pairs(P) do
            if p.inRace then
                local ped = GetPlayerPed(src)
                local veh = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
                if veh ~= 0 then
                    local v = GetEntityVelocity(veh)
                    local kmh = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) * 3.6
                    if kmh < 600 then
                        local lap = tonumber(Player(src).state.raceLap) or 1
                        local L = p.laps[lap]
                        if not L then L = { max = 0, sum = 0, n = 0 }; p.laps[lap] = L end
                        if kmh > L.max then L.max = kmh end
                        L.sum, L.n = L.sum + kmh, L.n + 1
                    end
                end
                if Analytics.OnRaceSample then Analytics.OnRaceSample(src, p, veh) end
            end
        end
    end
end)

-- Shared with server/race.lua.
Analytics = Analytics or {}
Analytics.P, Analytics.profileId, Analytics.raceId = P, profileId, raceId

-- ── Race results: finishes, DNFs, laps ───────────────────────────────────────

AddEventHandler("SPZ:raceEnd", function(results)
    if type(results) ~= "table" then return end
    local nowStr = DB.Now()
    local rid = results.raceId and tostring(results.raceId) or nil
    local trackName = tostring(results.track or "Unknown")
    local cls = results.carClass and tostring(results.carClass) or nil

    for _, f in ipairs(results.finishers or {}) do
        local src = f.source
        local p = P[src]
        local pid = profileId(src) or (p and p.pid)
        local pos = tonumber(f.position) or 0
        DB.Insert("race_queue_events", { "race_id", "player_id", "event", "detail", "created_at" },
            { rid, pid, "finish", tostring(pos), nowStr })
        local laps = type(f.lap_times) == "table" and f.lap_times or {}
        daily(pid, { finishes = 1, wins = pos == 1 and 1 or 0, podiums = (pos >= 1 and pos <= 3) and 1 or 0, laps = #laps })
        for lap, ms in ipairs(laps) do
            local L = p and p.laps[lap]
            DB.Insert("race_laps",
                { "race_id", "player_id", "track", "car_class", "lap", "lap_ms", "top_kmh", "avg_kmh", "created_at" },
                { rid or "?", pid, trackName, cls, lap, math.floor(tonumber(ms) or 0),
                  L and math.floor(L.max) or nil, (L and L.n > 0) and math.floor(L.sum / L.n) or nil, nowStr })
        end
        if p then p.laps = {} end
    end

    for _, d in ipairs(results.dnf or {}) do
        local src = d.source
        local p = P[src]
        local pid = profileId(src) or (p and p.pid)
        DB.Insert("race_queue_events", { "race_id", "player_id", "event", "detail", "created_at" },
            { rid, pid, "dnf", tostring(d.dnf_reason or "unknown"):sub(1, 64), nowStr })
        daily(pid, { dnfs = 1 })
        if p then p.laps = {} end
    end
end)

-- ── Server snapshot (once a minute) ──────────────────────────────────────────

local frameSum, frameN = 0, 0
CreateThread(function()
    local last = GetGameTimer()
    while true do
        Wait(0)
        local now = GetGameTimer()
        frameSum, frameN = frameSum + (now - last), frameN + 1
        last = now
    end
end)

local function snapshot()
    local c = { race = 0, queue = 0, timetrial = 0, minigame = 0, replay = 0, spectate = 0, freeroam = 0 }
    local buckets, pingSum, pingN, online = {}, 0, 0, 0
    for _, sid in ipairs(GetPlayers()) do
        local src = tonumber(sid)
        online = online + 1
        local m = (P[src] and P[src].mode) or modeOf(src)
        if c[m] then c[m] = c[m] + 1 else c.minigame = c.minigame + 1 end   -- pursuit/hideseek/...
        buckets[GetPlayerRoutingBucket(src)] = true
        local ping = GetPlayerPing(src) or 0
        if ping > 0 then pingSum, pingN = pingSum + ping, pingN + 1 end
    end
    local nb = 0
    for _ in pairs(buckets) do nb = nb + 1 end
    local frame = frameN > 0 and (frameSum / frameN) or nil
    frameSum, frameN = 0, 0
    DB.Insert("server_snapshots",
        { "taken_at", "players_online", "in_race", "in_queue", "in_timetrial", "in_minigame", "in_replay",
          "spectating", "freeroam", "buckets_active", "avg_ping", "frame_ms", "race_state",
          "vehicles", "peds", "objects" },
        { os.date("%Y-%m-%d %H:%M:00"), online, c.race, c.queue, c.timetrial, c.minigame, c.replay,
          c.spectate, c.freeroam, nb, pingN > 0 and math.floor(pingSum / pingN) or nil,
          frame and math.floor(frame * 100 + 0.5) / 100 or nil,
          GlobalState.raceState and tostring(GlobalState.raceState):sub(1, 16) or nil,
          #GetAllVehicles(), #GetAllPeds(), #GetAllObjects() }, true)
end

-- ── Retention ────────────────────────────────────────────────────────────────

local function prune()
    local days = Config.RetentionDays
    local jobs = {
        { "player_sessions", "ended_at" }, { "player_activity", "ended_at" },
        { "race_queue_events", "created_at" }, { "race_laps", "created_at" },
        { "server_snapshots", "taken_at" }, { "vehicle_usage", "ended_at" },
        { "race_engine_events", "created_at" }, { "connection_attempts", "created_at" },
    }
    for _, j in ipairs(jobs) do
        pcall(function()
            MySQL.update.await(("DELETE FROM `%s` WHERE `%s` < NOW() - INTERVAL ? DAY"):format(j[1], j[2]), { days })
        end)
    end
    print(("^2[spz-analytics] pruned rows older than %d days^7"):format(days))
end

-- ── Loops ────────────────────────────────────────────────────────────────────

CreateThread(function()
    -- Tables come from spz-core migrations; never write before they exist.
    local ok = pcall(function() return exports["spz-core"]:WaitForMigrations(120000) end)
    ready = true
    if not ok then print("^3[spz-analytics] could not confirm migrations, writing anyway^7") end

    for _, sid in ipairs(GetPlayers()) do track(tonumber(sid)) end   -- resource restarted mid-session
    print("^2[spz-analytics] collecting^7")
    prune()

    local nextSnap, nextFlush, nextPrune = 0, 0, os.time() + 86400
    while true do
        local now, nowStr = os.time(), DB.Now()
        for _, sid in ipairs(GetPlayers()) do
            local ok2, err = pcall(tickPlayer, tonumber(sid), now, nowStr)
            if not ok2 then print(("^1[spz-analytics] tick error: %s^7"):format(tostring(err))) end
        end
        if now >= nextSnap then nextSnap = now + Config.SnapshotSec; pcall(snapshot) end
        if now >= nextFlush then nextFlush = now + Config.FlushSec; DB.Flush() end
        if now >= nextPrune then nextPrune = now + 86400; prune() end
        Wait(Config.TickSec * 1000)
    end
end)

-- A restart closes everyone's open rows so nothing is lost; the new instance
-- re-opens them on its first tick.
AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() or not ready then return end
    for src in pairs(P) do untrack(src, "analytics restart") end
    DB.Flush()
end)

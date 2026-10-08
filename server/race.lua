-- server/race.lua — per-race detail on top of server/main.lua.
--
--   race_entries           one row per racer per race: car (rental/owned),
--                          result, and ping + FPS during the race
--   race_engine_events     every race-state change with the time spent in
--                          the previous state, plus failures spz-races
--                          reports through the Event export
--   player_rating_history  iRating / SR / rank / license before and after

local A = Analytics

local ENTRY_COLS = { "race_id", "player_id", "track", "race_type", "car_class", "model", "rental", "racers",
    "position", "dnf", "dnf_reason", "finish_ms", "best_lap_ms", "incidents", "avg_ping", "max_ping",
    "avg_fps", "min_fps", "created_at" }

local function ratings(src)
    local st = Player(src).state
    return {
        ir   = tonumber(st.iRating),
        sr   = tonumber(st.sr),
        rank = st.rank and tostring(st.rank):sub(1, 16) or nil,
        lic  = tonumber(st.licenseTier),
    }
end

-- ── Race start: reset the per-race accumulators ──────────────────────────────

function A.OnRaceStart(src, p)
    p.rnet   = { sum = 0, n = 0, max = 0 }
    p.rfps   = { sum = 0, n = 0, min = nil }
    p.car    = nil
    p.before = ratings(src)
end

-- Every Config.LapSampleMs while racing (from main.lua's lap sampler).
function A.OnRaceSample(src, p, veh)
    local net = p.rnet
    if not net then A.OnRaceStart(src, p); net = p.rnet end
    local ping = GetPlayerPing(src) or 0
    if ping > 0 then
        net.sum, net.n = net.sum + ping, net.n + 1
        if ping > net.max then net.max = ping end
    end
    -- The race car, once spz-vehicles has spawned it.
    if not p.car and veh ~= 0 and GetResourceState("spz-vehicles") == "started" then
        local ok, v = pcall(function() return exports["spz-vehicles"]:GetPlayerVehicle(src) end)
        if ok and v and v.entity == veh then
            p.car = { model = v.model and tostring(v.model) or tostring(GetEntityModel(veh)), rental = v.isRental and 1 or 0 }
        end
    end
end

-- FPS, reported by the racer's client every 10 s while racing.
RegisterNetEvent("spz-analytics:fps", function(avg, low, samples)
    local p = A.P[source]
    if not p or not p.inRace then return end
    avg, low, samples = tonumber(avg), tonumber(low), tonumber(samples)
    if not avg or not low or not samples or avg <= 0 or avg > 1000 or low <= 0 or low > 1000 then return end
    samples = math.max(1, math.min(samples, 60))
    local f = p.rfps
    if not f then A.OnRaceStart(source, p); f = p.rfps end
    f.sum, f.n = f.sum + avg * samples, f.n + samples
    if not f.min or low < f.min then f.min = low end
end)

-- ── Race end: entries now, ratings once progression has applied them ────────

AddEventHandler("SPZ:raceEnd", function(results)
    if type(results) ~= "table" then return end
    local nowStr = DB.Now()
    local rid = tostring(results.raceId or "?")
    local trackName = tostring(results.track or "Unknown")
    local rtype = results.type and tostring(results.type):sub(1, 16) or nil
    local cls = results.carClass and tostring(results.carClass) or nil
    local racers = #(results.finishers or {}) + #(results.dnf or {})
    local srcs = {}

    local function entry(src, e, dnf)
        local p = A.P[src]
        local net, fps, car = p and p.rnet, p and p.rfps, p and p.car
        local pid = A.profileId(src) or (p and p.pid)
        srcs[#srcs + 1] = src
        DB.Insert("race_entries", ENTRY_COLS, {
            rid, pid, trackName, rtype, cls,
            car and car.model or nil, car and car.rental or nil, racers,
            (not dnf) and tonumber(e.position) or nil, dnf and 1 or 0,
            dnf and tostring(e.dnf_reason or "unknown"):sub(1, 64) or nil,
            (not dnf and tonumber(e.finish_time)) and math.floor(tonumber(e.finish_time)) or nil,
            tonumber(e.best_lap) and math.floor(tonumber(e.best_lap)) or nil,
            type(e.collisions) == "table" and #e.collisions or nil,
            (net and net.n > 0) and math.floor(net.sum / net.n) or nil, (net and net.n > 0) and net.max or nil,
            (fps and fps.n > 0) and math.floor(fps.sum / fps.n + 0.5) or nil, fps and fps.min and math.floor(fps.min) or nil,
            nowStr,
        })
    end
    for _, f in ipairs(results.finishers or {}) do entry(f.source, f, false) end
    for _, d in ipairs(results.dnf or {}) do entry(d.source, d, true) end

    for _, src in ipairs(srcs) do
        local p = A.P[src]
        if p then p.before, p.rnet, p.rfps, p.car = nil, nil, nil, nil end
    end
end)

-- ── Ratings: written from spz-progression's own before/after ─────────────────
-- This used to wait a blind 15 s after SPZ:raceEnd and diff statebags, which
-- missed slow DB writes and mislabelled anything that changed in between.
-- spz-progression now fires SPZ:progressionApplied once per race with the
-- exact before/after values it applied.
AddEventHandler("SPZ:progressionApplied", function(data)
    if type(data) ~= "table" or type(data.players) ~= "table" then return end
    local stamp = DB.Now()
    local rid = data.raceId and tostring(data.raceId) or nil
    for _, a in ipairs(data.players) do
        if a.playerId and (a.irAfter ~= a.irBefore or a.srAfter ~= a.srBefore
                           or a.rankAfter ~= a.rankBefore or a.tierAfter ~= a.tierBefore) then
            DB.Insert("player_rating_history",
                { "player_id", "race_id", "irating", "irating_change", "sr", "sr_change",
                  "rank_title", "rank_before", "license_tier", "license_before", "created_at" },
                { a.playerId, rid, a.irAfter, (a.irAfter or 0) - (a.irBefore or 0),
                  a.srAfter, math.floor(((a.srAfter or 0) - (a.srBefore or 0)) * 100 + 0.5) / 100,
                  a.rankAfter and tostring(a.rankAfter):sub(1, 16) or nil,
                  a.rankBefore and tostring(a.rankBefore):sub(1, 16) or nil,
                  a.tierAfter, a.tierBefore, stamp })
        end
    end
end)

-- ── Race engine ──────────────────────────────────────────────────────────────

local ENGINE_COLS = { "race_id", "event", "detail", "player_id", "players", "duration_ms", "created_at" }
local stateSince = GetGameTimer()

local function queued()
    if GetResourceState("spz-races") ~= "started" then return nil end
    local ok, n = pcall(function() return exports["spz-races"]:GetQueueCount() end)
    return ok and tonumber(n) or nil
end

AddStateBagChangeHandler("raceState", "global", function(_, _, value)
    if not value then return end
    local now = GetGameTimer()
    DB.Insert("race_engine_events", ENGINE_COLS,
        { A.raceId(), "state", tostring(value):sub(1, 128), nil, queued(), now - stateSince, DB.Now() })
    stateSince = now
end)

--- Called by spz-races on failures:
---   exports["spz-analytics"]:Event("spawn_fail", detail, src)
local function engineEvent(event, detail, src)
    if type(event) ~= "string" then return end
    src = tonumber(src)
    DB.Insert("race_engine_events", ENGINE_COLS,
        { A.raceId(), event:sub(1, 32), detail and tostring(detail):sub(1, 128) or nil,
          src and A.profileId(src) or nil, queued(), nil, DB.Now() })
end
exports("Event", engineEvent)

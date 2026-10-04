-- client/main.lua — the only thing the server can't see for itself:
-- minigames set inMinigame on the client only, so report it when it changes.
-- Also relays feature-usage pings from other client scripts:
--   TriggerEvent("spz-analytics:feature", "leaderboard_open")

local last = nil

CreateThread(function()
    while true do
        local v = LocalPlayer.state.inMinigame
        v = type(v) == "string" and v or false
        if v ~= last then
            last = v
            TriggerServerEvent("spz-analytics:mode", v or "")
        end
        Wait(2000)
    end
end)

AddEventHandler("spz-analytics:feature", function(feature)
    if type(feature) == "string" then TriggerServerEvent("spz-analytics:feature", feature) end
end)

-- FPS while racing: every 10 s, the average and the worst second, so the
-- server can store per-race / per-track performance (race_entries).
CreateThread(function()
    local frames, secStart, secFrames = 0, GetGameTimer(), 0
    local sumFps, nSec, low = 0, 0, nil
    local lastSend = GetGameTimer()
    while true do
        if LocalPlayer.state.inRace then
            Wait(0)
            secFrames = secFrames + 1
            local now = GetGameTimer()
            if now - secStart >= 1000 then
                local fps = secFrames * 1000 / (now - secStart)
                sumFps, nSec = sumFps + fps, nSec + 1
                if not low or fps < low then low = fps end
                secStart, secFrames = now, 0
            end
            if now - lastSend >= 10000 and nSec > 0 then
                TriggerServerEvent("spz-analytics:fps", sumFps / nSec, low, nSec)
                sumFps, nSec, low, lastSend = 0, 0, nil, now
            end
        else
            sumFps, nSec, low = 0, 0, nil
            secStart, secFrames, lastSend = GetGameTimer(), 0, GetGameTimer()
            Wait(1000)
        end
    end
end)

-- Tell the server once we're actually in the world (connection load time).
CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) or not IsScreenFadedIn() or IsPlayerSwitchInProgress() do
        Wait(500)
    end
    TriggerServerEvent("spz-analytics:spawned")
end)

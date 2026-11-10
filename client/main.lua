local resourceName = GetCurrentResourceName()
local config = json.decode(LoadResourceFile(resourceName, 'config.json') or '{}') or {}
local dropConfig = config.skyDrop or {}

local LOADSCREEN_RESOURCE = dropConfig.loadingScreenResource or 'cfx-swr-loadingscreen'
local SKY_HOLD_MS = dropConfig.skyHoldMs or 1500
local COLLISION_TIMEOUT = dropConfig.collisionTimeoutMs or 15000
-- Switch flags for the ascent. 16384 = SWITCH_FLAG_SUPPRESS_INTRO_FX: the ascent
-- happens behind the loading screen, so its whooshes/flashes would otherwise be
-- heard through it. The descent (SwitchInPlayer) keeps all of its effects.
local SWITCH_OUT_FLAGS = dropConfig.switchOutFlags or 16384
-- How long we'll wait on the server before letting the loading screen go anyway.
local SERVER_REPLY_TIMEOUT = 15000

-- GTA's player switch states: 5 = camera parked in the sky, waiting for SwitchIn.
local SWITCH_STATE_SKY_HOLD = 5

local firstSpawnHandled = false
local spawnApplied = false
-- Only true once the player is standing at their real spot. Nothing is saved
-- before this, so a slow load can't overwrite the saved spot with wherever
-- spawnmanager parked the ped first.
local spawnComplete = false
local loadscreenClosed = false

AddEventHandler('cfx-swr-loadingscreen:closed', function()
    loadscreenClosed = true
end)

local function loadscreenProgress(fraction, label)
    TriggerEvent('cfx-swr-loadingscreen:progress', fraction, label)
end

local function releaseLoadscreen()
    TriggerEvent('cfx-swr-loadingscreen:release')
end

local function waitFor(predicate, timeout, interval)
    local start = GetGameTimer()
    while not predicate() do
        if GetGameTimer() - start >= timeout then
            return false
        end
        Wait(interval or 0)
    end
    return true
end

local function markSpawnComplete()
    spawnComplete = true
    TriggerServerEvent('persistentspawn:server:spawnComplete')
end

local function saveCurrentPosition()
    if not spawnComplete then
        return
    end

    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) or IsPlayerSwitchInProgress() then
        return
    end

    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    TriggerServerEvent('persistentspawn:server:saveSpawn', {
        x = coords.x,
        y = coords.y,
        z = coords.z,
        heading = heading
    })
end

-- Moves the ped to the spawn and holds it there until the world has streamed in
-- around it. `onProgress` gets 0-1 while we wait.
local function placePed(spawn, onProgress)
    local ped = PlayerPedId()
    local x, y, z = spawn.x + 0.0, spawn.y + 0.0, spawn.z + 0.0

    FreezeEntityPosition(ped, true)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, (spawn.heading or 0.0) + 0.0)

    local start = GetGameTimer()
    while not HasCollisionLoadedAroundEntity(ped) do
        local elapsed = GetGameTimer() - start
        if elapsed >= COLLISION_TIMEOUT then
            break
        end

        RequestCollisionAtCoord(x, y, z)
        if onProgress then
            onProgress(elapsed / COLLISION_TIMEOUT)
        end
        Wait(50)
    end
end

-- Keeps the HUD, radar and controls off for as long as `isActive()` holds.
local function suppressHud(isActive)
    CreateThread(function()
        while isActive() do
            HideHudAndRadarThisFrame()
            DisableAllControlActions(0)
            Wait(0)
        end
    end)
end

--[[
    GTA Online style drop-in. SwitchOutPlayer/SwitchInPlayer are the game's own
    multiplayer player switch (SWITCH_TO_MULTI_FIRSTPART / SECONDPART), so the
    clouds, the stepped descent, the whoosh audio and the flash pulses are all
    Rockstar's, not a recreation.

      1. Behind the loading screen: move the ped and wait for collisions.
      2. Still hidden: pull the camera up into the sky above the spot.
      3. Release the loading screen. The player now sees the sky.
      4. Hold for a beat, then drop down to the ped.
]]
local function skyDrop(spawn)
    local dropping = true
    suppressHud(function() return dropping end)

    loadscreenProgress(0.3, 'Loading your area...')
    placePed(spawn, function(p)
        loadscreenProgress(0.3 + p * 0.5, 'Loading your area...')
    end)

    -- spawnmanager fades out while it places the ped. Make sure the world behind
    -- the NUI is visible for when it lifts.
    if not IsScreenFadedIn() then
        DoScreenFadeIn(0)
    end

    loadscreenProgress(0.85, 'Getting ready to drop in...')
    SwitchOutPlayer(PlayerPedId(), SWITCH_OUT_FLAGS, 1)

    local inSky = waitFor(function()
        return GetPlayerSwitchState() == SWITCH_STATE_SKY_HOLD
    end, 12000, 0)

    releaseLoadscreen()
    waitFor(function() return loadscreenClosed end, 5000, 50)

    if inSky then
        Wait(SKY_HOLD_MS)
        SwitchInPlayer(PlayerPedId())
        waitFor(function() return not IsPlayerSwitchInProgress() end, 20000, 0)
    elseif IsPlayerSwitchInProgress() then
        -- Switch never reached the sky; drop it rather than leave the camera stuck.
        StopPlayerSwitch()
    end

    FreezeEntityPosition(PlayerPedId(), false)
    dropping = false
end

-- Plain teleport behind a fade. Used when the loading screen isn't running or
-- already closed, or when the sky drop is turned off in config.
local function fadeTeleport(spawn)
    DoScreenFadeOut(250)
    waitFor(function() return IsScreenFadedOut() end, 2000, 0)

    placePed(spawn)
    FreezeEntityPosition(PlayerPedId(), false)

    DoScreenFadeIn(250)
end

RegisterNetEvent('persistentspawn:client:applySpawn', function(spawn)
    if spawnApplied then
        return
    end
    spawnApplied = true

    if not spawn or not spawn.x or not spawn.y or not spawn.z then
        releaseLoadscreen()
        markSpawnComplete()
        return
    end

    local canDrop = dropConfig.enabled ~= false
        and GetResourceState(LOADSCREEN_RESOURCE) == 'started'
        and not loadscreenClosed

    if canDrop then
        skyDrop(spawn)
    else
        releaseLoadscreen()
        fadeTeleport(spawn)
    end

    markSpawnComplete()
end)

AddEventHandler('playerSpawned', function()
    if firstSpawnHandled then
        return
    end

    firstSpawnHandled = true
    loadscreenProgress(0.15, 'Finding your spot...')
    TriggerServerEvent('persistentspawn:server:requestSpawn')

    -- If the server never answers, don't leave the player on the loading screen.
    SetTimeout(SERVER_REPLY_TIMEOUT, function()
        if not spawnApplied then
            spawnApplied = true
            releaseLoadscreen()
            markSpawnComplete()
        end
    end)
end)

-- Resource restarted mid-session: the player is already in the world and
-- playerSpawned won't fire again, so pick up saving straight away.
CreateThread(function()
    if NetworkIsSessionStarted() and not GetIsLoadingScreenActive() then
        firstSpawnHandled = true
        spawnApplied = true
        markSpawnComplete()
    end
end)

CreateThread(function()
    local interval = config.autoSaveIntervalMs or 30000

    while true do
        Wait(interval)
        saveCurrentPosition()
    end
end)

AddEventHandler('onResourceStop', function(stoppedResourceName)
    if stoppedResourceName ~= resourceName then
        return
    end

    saveCurrentPosition()
end)

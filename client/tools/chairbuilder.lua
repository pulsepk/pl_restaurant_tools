-- ── Restaurant Tools — Chair Group Builder ───────────────────────────────────
-- Command : /<Config.CommandPrefix>chair  (set Config.CommandPrefix in shared/config.lua)
-- Access  : ace permission  pl_restaurant.locationbuilder
--
-- Flow:
--   1. Input dialog  → group name, interaction type, zone radius
--   2. Place zone centre
--   3. For each chair:
--        a. Input chair label
--        b. Place SIT  position — ghost ped in sit anim, scroll to adjust Z, Q/E heading
--        c. Place STAND position — cone, scroll to adjust Z
--   4. Generate code → F8 + server console
--
-- Controls shared by all placement steps:
--   Aim      → move X/Y via camera raycast
--   Scroll ↑ → raise Z by 0.05
--   Scroll ↓ → lower Z by 0.05
--   ENTER    → confirm
--   BACKSPACE→ cancel / go back

local isBuildingChair = false
local ChairBuilder          -- forward-declared: used in RegisterCommand before definition
local PlaceSitPoint         -- forward-declared: used in ChairBuilder.askChairLabel
local PlacePoint            -- forward-declared: used in ChairBuilder methods

-- ── Permission gate ───────────────────────────────────────────────────────────

RegisterCommand(Config.CommandPrefix .. 'chair', function()
    if isBuildingChair then return end
    lib.callback(ResourceEvent('hasBuilderAccess'), false, function(ok)
        if not ok then
            Notify('You do not have permission to use the chair builder.', 'error')
            return
        end
        ChairBuilder.start()
    end)
end, false)

-- ── Shared raycast helper ─────────────────────────────────────────────────────

local function RotationToDir(rot)
    local z = math.rad(rot.z)
    local x = math.rad(rot.x)
    return vector3(-math.sin(z) * math.abs(math.cos(x)),
                    math.cos(z) * math.abs(math.cos(x)),
                    math.sin(x))
end

local function GetGroundHit()
    local cam  = GetGameplayCamCoord()
    local dest = cam + RotationToDir(GetGameplayCamRot(2)) * 12.0
    local ray  = StartShapeTestRay(cam, dest, -1, PlayerPedId(), 0)
    local _, hit, coords = GetShapeTestResult(ray)
    return (hit and hit ~= 0 and coords) or dest
end

-- ── 3-D Z readout drawn above a world position ───────────────────────────────

local function Draw3dLabel(x, y, z, text)
    local onScreen, sx, sy = World3dToScreen2d(x, y, z)
    if not onScreen then return end
    SetTextScale(0.3, 0.3)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 230)
    SetTextOutline()
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(sx, sy)
end

-- ── Generic cone-placement (zone centre, stand position) ─────────────────────
-- Scroll ↑/↓ : ±0.05 Z
-- ENTER       : confirm → cb(coords, heading)
-- BACKSPACE   : cancel  → cb(nil)
-- trackHeading: if true, Q/E rotate 5°

local CONE_MODEL = 'prop_mp_cone_01'

PlacePoint = function(hintText, trackHeading, cb)
    local hash     = GetHashKey(CONE_MODEL)
    local heading  = GetEntityHeading(PlayerPedId())
    local zAdjust  = 0.0
    local onGround = false

    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 50 do Wait(100); t = t + 1 end

    local pt    = GetEntityCoords(PlayerPedId())
    local ghost = CreateObject(hash, pt.x, pt.y, pt.z, false, false, false)
    SetEntityAlpha(ghost, 160, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)

    local hint = hintText .. '  |  [ENTER] Confirm  [Scroll] Z ±0.05'
    if trackHeading then hint = hint .. '  [Q/E] Rotate' end
    hint = hint .. '  [G] Snap to Ground  [BACKSPACE] Cancel'
    TextUIShow(hint, { position = 'left-center', icon = 'fas fa-map-pin' })

    CreateThread(function()
        while true do
            local base   = GetGroundHit()
            local finalZ = base.z + zAdjust

            if DoesEntityExist(ghost) then
                SetEntityCoordsNoOffset(ghost, base.x, base.y, finalZ, false, false, false)
                SetEntityHeading(ghost, heading)
            end

            Draw3dLabel(base.x, base.y, finalZ + 0.8,
                ('Z: %.3f%s'):format(finalZ, onGround and '  [On Ground]' or ''))

            DisableControlAction(0, 44,  true)  -- Q
            DisableControlAction(0, 38,  true)  -- E
            DisableControlAction(0, 47,  true)  -- G
            DisableControlAction(0, 18,  true)  -- ENTER
            DisableControlAction(0, 177, true)  -- BACKSPACE
            DisableControlAction(0, 241, true)  -- Scroll up
            DisableControlAction(0, 242, true)  -- Scroll down

            if trackHeading then
                if IsDisabledControlJustPressed(0, 44) then heading = (heading - 5.0) % 360.0; onGround = false end
                if IsDisabledControlJustPressed(0, 38) then heading = (heading + 5.0) % 360.0; onGround = false end
            end
            if IsDisabledControlJustPressed(0, 241) then zAdjust = zAdjust + 0.05; onGround = false end
            if IsDisabledControlJustPressed(0, 242) then zAdjust = zAdjust - 0.05; onGround = false end

            if IsDisabledControlJustPressed(0, 47) and DoesEntityExist(ghost) then
                PlaceObjectOnGroundProperly(ghost)
                zAdjust  = GetEntityCoords(ghost).z - base.z
                onGround = true
            end

            if IsDisabledControlJustPressed(0, 18) then
                local finalPos = vector3(base.x, base.y, finalZ)
                TextUIHide()
                if DoesEntityExist(ghost) then DeleteObject(ghost) end
                SetModelAsNoLongerNeeded(hash)
                cb(finalPos, heading)
                return
            end

            if IsDisabledControlJustPressed(0, 177) then
                TextUIHide()
                if DoesEntityExist(ghost) then DeleteObject(ghost) end
                SetModelAsNoLongerNeeded(hash)
                cb(nil)
                return
            end

            Wait(0)
        end
    end)
end

-- ── Sit-position placement with ghost ped ─────────────────────────────────────
-- Clones the player ped (no model loading needed) as the ghost.
-- Uses TaskStartScenarioInPlace with PROP_HUMAN_SEAT_CHAIR_MP_PLAYER so the
-- game handles the sitting animation internally — no animDict loading required.
-- Ghost position tracked with StartShapeTestSweptSphere (smoother than a ray).
--
-- Stored Z is what goes into location.lua.
-- Ghost ped is rendered at storedZ + SIT_Z_OFFSET so the visual matches the
-- actual seat position (TaskStartScenarioAtPosition applies that same offset).
--
-- Q / E        → heading ±5°
-- Scroll ↑/↓  → storedZ ±0.05
-- ENTER        → confirm → cb(storedCoords, heading)
-- BACKSPACE    → cancel  → cb(nil)

local SIT_Z_OFFSET = -0.5   -- matches TaskStartScenarioAtPosition z offset in interaction.lua

local function GetSweptHit(ignoreEnt)
    local camRot = GetGameplayCamRot()
    local camPos = GetGameplayCamCoord()
    local dir    = RotationToDir(camRot)
    local dest   = camPos + dir * 10.0
    local cast   = StartShapeTestSweptSphere(
        camPos.x, camPos.y, camPos.z,
        dest.x,   dest.y,   dest.z,
        0.2, 339, ignoreEnt, 4)
    local _, hit, coords = GetShapeTestResult(cast)
    return (hit and hit ~= 0 and coords) or dest
end

PlaceSitPoint = function(cb)
    local playerPed = PlayerPedId()

    -- Clone the player as the ghost — no model request needed
    local ghostPed = ClonePed(playerPed, false, false, false)
    SetEntityAlpha(ghostPed, 160, false)
    SetEntityCollision(ghostPed, false, false)
    FreezeEntityPosition(ghostPed, true)
    SetBlockingOfNonTemporaryEvents(ghostPed, true)
    SetEntityInvincible(ghostPed, true)
    SetEntityCanBeDamaged(ghostPed, false)
    SetPedCanRagdoll(ghostPed, false)

    -- Give the ped a moment to fully spawn before starting the scenario
    Wait(100)

    TaskStartScenarioInPlace(ghostPed, 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER', 0, true)

    local heading  = GetEntityHeading(playerPed)
    local zAdjust  = 0.0
    local onGround = false

    local function showHint()
        TextUIShow(('SIT position  |  H: %.1f°  |  [ENTER] Confirm  [Scroll] Z ±0.05  [Q/E] Rotate ±5°  [G] Snap to Ground  [BACKSPACE] Cancel'):format(heading), {
            position = 'left-center',
            icon     = 'fas fa-chair',
        })
    end
    showHint()

    CreateThread(function()
        while true do
            local base    = GetSweptHit(ghostPed)
            local storedZ = base.z + zAdjust
            local pedZ    = storedZ + SIT_Z_OFFSET

            SetEntityCoordsNoOffset(ghostPed, base.x, base.y, pedZ, false, false, false)
            SetEntityHeading(ghostPed, heading)

            if not IsPedUsingScenario(ghostPed, 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER') then
                TaskStartScenarioInPlace(ghostPed, 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER', 0, true)
            end

            Draw3dLabel(base.x, base.y, pedZ + 1.2,
                ('Z: %.3f  (stored: %.3f)  H: %.1f°%s'):format(pedZ, storedZ, heading, onGround and '  [On Ground]' or ''))

            DisableControlAction(0, 44,  true)
            DisableControlAction(0, 38,  true)
            DisableControlAction(0, 47,  true)  -- G
            DisableControlAction(0, 18,  true)
            DisableControlAction(0, 177, true)
            DisableControlAction(0, 241, true)
            DisableControlAction(0, 242, true)

            if IsDisabledControlJustPressed(0, 44) then
                heading = (heading - 5.0) % 360.0
                onGround = false
                showHint()
            end
            if IsDisabledControlJustPressed(0, 38) then
                heading = (heading + 5.0) % 360.0
                onGround = false
                showHint()
            end
            if IsDisabledControlJustPressed(0, 241) then zAdjust = zAdjust + 0.05; onGround = false end
            if IsDisabledControlJustPressed(0, 242) then zAdjust = zAdjust - 0.05; onGround = false end

            if IsDisabledControlJustPressed(0, 47) and DoesEntityExist(ghostPed) then
                PlaceObjectOnGroundProperly(ghostPed)
                -- The ghost is rendered at storedZ + SIT_Z_OFFSET, so undo that
                -- offset when reading the snapped position back, otherwise the
                -- stored value would drift by SIT_Z_OFFSET every time this is pressed.
                zAdjust  = (GetEntityCoords(ghostPed).z - SIT_Z_OFFSET) - base.z
                onGround = true
            end

            if IsDisabledControlJustPressed(0, 18) then
                TextUIHide()
                if DoesEntityExist(ghostPed) then DeletePed(ghostPed) end
                cb(vector3(base.x, base.y, storedZ), heading)
                return
            end

            if IsDisabledControlJustPressed(0, 177) then
                TextUIHide()
                if DoesEntityExist(ghostPed) then DeletePed(ghostPed) end
                cb(nil)
                return
            end

            Wait(0)
        end
    end)
end

-- ── Builder state + flow ──────────────────────────────────────────────────────

ChairBuilder = {
    group  = nil,
    chairs = {},

    start = function()
        isBuildingChair     = true
        ChairBuilder.group  = nil
        ChairBuilder.chairs = {}
        ChairBuilder.askGroupInfo()
    end,

    askGroupInfo = function()
        local input = lib.inputDialog('Chair Group Builder', {
            { type = 'input',  label = 'Group Name',       placeholder = 'Table 1', required = true },
            { type = 'select', label = 'Interaction Type', options = {
                { value = 'target', label = 'Target — box zone per chair'    },
                { value = 'zone',   label = 'Zone — sphere, [E] picks seat'  },
                { value = 'text3d', label = '3D Text — floating prompt, [E] picks seat' },
            }, default = 'target' },
            { type = 'number', label = 'Zone Radius', default = 2.0, min = 0.5, max = 15.0 },
        })

        if not input then
            isBuildingChair = false
            return
        end

        ChairBuilder.group = {
            name        = tostring(input[1]),
            Interaction = tostring(input[2]),
            radius      = tonumber(input[3]) or 2.0,
            zone        = nil,
        }

        PlacePoint('Zone centre', false, function(coords)
            if not coords then
                isBuildingChair = false
                Notify('Chair builder cancelled.', 'inform')
                return
            end
            ChairBuilder.group.zone = coords
            ChairBuilder.promptAddChair()
        end)
    end,

    promptAddChair = function()
        local count  = #ChairBuilder.chairs
        local result = lib.alertDialog({
            header   = ('"%s" — %d chair(s) added'):format(ChairBuilder.group.name, count),
            content  = count == 0
                and 'Place the first chair in this group.'
                or  'Add another chair, or finish to generate the code.',
            centered = true,
            cancel   = count > 0,
        })

        if result == 'confirm' then
            ChairBuilder.askChairLabel()
        else
            ChairBuilder.finish()
        end
    end,

    askChairLabel = function()
        local idx     = #ChairBuilder.chairs + 1
        local default = 'Chair ' .. idx
        local input   = lib.inputDialog('Chair ' .. idx .. ' — Label', {
            { type = 'input', label = 'Label', placeholder = default },
        })
        local label = (input and input[1] and input[1] ~= '') and input[1] or default

        -- Step 1: sit position with ghost ped
        PlaceSitPoint(function(sitCoords, sitHeading)
            if not sitCoords then
                Notify('Sit placement cancelled. Back to group menu.', 'inform')
                ChairBuilder.promptAddChair()
                return
            end

            -- Step 2: stand position with cone + Z scroll
            PlacePoint('STAND position (where ped stands up)', false, function(standCoords)
                if not standCoords then
                    Notify('Stand placement cancelled. Back to group menu.', 'inform')
                    ChairBuilder.promptAddChair()
                    return
                end

                table.insert(ChairBuilder.chairs, {
                    label  = label,
                    coords = { x = sitCoords.x,   y = sitCoords.y,   z = sitCoords.z,   h = sitHeading },
                    stand  = { x = standCoords.x, y = standCoords.y, z = standCoords.z },
                })

                ChairBuilder.promptAddChair()
            end)
        end)
    end,

    generateCode = function()
        local g     = ChairBuilder.group
        local lines = { '    {' }

        lines[#lines+1] = ('        name        = %q,'):format(g.name)
        lines[#lines+1] = ('        Interaction = %q,'):format(g.Interaction)
        lines[#lines+1] = ('        zone        = vector3(%s, %s, %s),'):format(
            ('%.2f'):format(g.zone.x), ('%.2f'):format(g.zone.y), ('%.2f'):format(g.zone.z))
        lines[#lines+1] = ('        radius      = %s,'):format(g.radius)
        lines[#lines+1] = '        chairs      = {'

        for _, c in ipairs(ChairBuilder.chairs) do
            local z0 = ('%.1f'):format(c.coords.z - 0.3)
            local z1 = ('%.1f'):format(c.coords.z + 0.5)
            lines[#lines+1] = ('            { label = %q, coords = vector4(%s, %s, %s, %s), stand = vector3(%s, %s, %s), minZ = %s, maxZ = %s, w = 0.3, h = 0.45, height = 0.45 },'):format(
                c.label,
                ('%.2f'):format(c.coords.x), ('%.2f'):format(c.coords.y),
                ('%.2f'):format(c.coords.z), ('%.2f'):format(c.coords.h),
                ('%.2f'):format(c.stand.x),  ('%.2f'):format(c.stand.y),
                ('%.2f'):format(c.stand.z),
                z0, z1)
        end

        lines[#lines+1] = '        },'
        lines[#lines+1] = '    },'
        return table.concat(lines, '\n')
    end,

    finish = function()
        local code = ChairBuilder.generateCode()

        print(('\n%s\n[Restaurant Tools] Chair Builder — paste into Location.ChairGroups in location.lua:\n%s\n%s\n')
            :format(('='):rep(60), code, ('='):rep(60)))

        TriggerServerEvent(ResourceEvent('chairbuilder:output'), code)

        isBuildingChair = false

        lib.alertDialog({
            header   = 'Chair Builder — Done',
            content  = ('**Group:** `%s`  \n**Chairs:** %d  \n\nCode in **F8 console** and **server console**.\nPaste inside `Location.ChairGroups = { ... }` in `location.lua`.'):format(
                ChairBuilder.group.name, #ChairBuilder.chairs),
            centered = true,
            cancel   = false,
        })
    end,
}

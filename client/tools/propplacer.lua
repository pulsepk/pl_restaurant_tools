-- ── Restaurant Tools — Prop Placer ────────────────────────────────────────────
-- Command : /<Config.CommandPrefix>prop  (set Config.CommandPrefix in shared/config.lua)
-- Access  : ace permission  pl_restaurant.locationbuilder
--
-- Quick tool to get a vec3/vec4 for where a prop should sit — e.g. cooking
-- station prop tables, item spawn points, or any prop needing a heading (TVs,
-- decor, etc). Spawns the real model so you can see exactly how it rests,
-- move it around by looking where you want it, fine-tune height with scroll
-- and rotation with Q/E, confirm to print both forms.
--
-- Flow:
--   1. Input dialog → pick a prop from the dropdown, or "Custom" + type a name
--   2. Aim to move X/Y, scroll to nudge Z up/down, Q/E to rotate, G to snap
--      to the ground beneath it, ENTER to confirm
--   3. vec3(...) and vec4(...) (with heading) printed to F8 + server console

local isPlacing = false
local ModelChoice
local StartPlacement
local FinishPlacement

-- ── Permission gate ───────────────────────────────────────────────────────────

RegisterCommand(Config.CommandPrefix .. 'prop', function()
    if isPlacing then return end
    lib.callback(ResourceEvent('hasBuilderAccess'), false, function(ok)
        if not ok then
            Notify('You do not have permission to use the prop placer.', 'error')
            return
        end
        ModelChoice()
    end)
end, false)

-- ── Dialog ────────────────────────────────────────────────────────────────────

local MODELS = {
    { value = 'pl_rawpatty',       label = 'Raw Patty (pl_rawpatty)' },
    { value = 'pl_burgerbun',      label = 'Burger Bun (pl_burgerbun)' },
    { value = 'pl_fries',          label = 'Fries (pl_fries)' },
    { value = 'prop_cs_burger_01', label = 'Finished Burger (prop_cs_burger_01)' },
    { value = 'prop_tv_flat_01',   label = 'TV Display Board (prop_tv_flat_01)' },
    { value = 'custom',            label = 'Custom (type below)' },
}

ModelChoice = function()
    local input = lib.inputDialog('Prop Placer', {
        { type = 'select', label = 'Prop Model',        options = MODELS, default = 'pl_rawpatty' },
        { type = 'input',  label = 'Custom Model Name', placeholder = 'e.g. prop_cs_burger_01', description = 'Only used if "Custom" is selected above' },
    })

    if not input then return end

    local model = tostring(input[1])
    if model == 'custom' then
        model = type(input[2]) == 'string' and input[2]:match('^%s*(.-)%s*$') or ''
        if model == '' then
            Notify('Enter a custom model name.', 'error')
            return
        end
    end

    StartPlacement(model)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function RotationToDir(rot)
    local z   = math.rad(rot.z)
    local x   = math.rad(rot.x)
    local cos = math.abs(math.cos(x))
    return vector3(-math.sin(z) * cos, math.cos(z) * cos, math.sin(x))
end

local function GetCameraGroundPoint()
    local camPos = GetGameplayCamCoord()
    local dest   = camPos + RotationToDir(GetGameplayCamRot(2)) * 12.0
    local ray    = StartShapeTestRay(camPos, dest, -1, PlayerPedId(), 0)
    local _, hit, coords = GetShapeTestResult(ray)
    return (hit and hit ~= 0 and coords) or dest
end

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

-- ── Placement ─────────────────────────────────────────────────────────────────

StartPlacement = function(model)
    isPlacing = true

    local hash = GetHashKey(model)
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 100 do Wait(100); t = t + 1 end

    if not HasModelLoaded(hash) then
        isPlacing = false
        Notify(('Model "%s" failed to load — check the name.'):format(model), 'error')
        return
    end

    local pt      = GetEntityCoords(PlayerPedId())
    local heading = GetEntityHeading(PlayerPedId())
    local ghost   = CreateObject(hash, pt.x, pt.y, pt.z, false, false, false)
    SetEntityAlpha(ghost, 200, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)

    local zAdjust  = 0.0
    local onGround = false

    TextUIShow(('Placing "%s"  |  [ENTER] Confirm  [Scroll] Up/Down ±0.05  [Q/E] Rotate ±5°  [G] Snap to Ground  [BACKSPACE] Cancel'):format(model), {
        position = 'left-center',
        icon     = 'fas fa-cube',
    })

    CreateThread(function()
        while isPlacing do
            local base   = GetCameraGroundPoint()
            local finalZ = base.z + zAdjust

            if DoesEntityExist(ghost) then
                SetEntityCoordsNoOffset(ghost, base.x, base.y, finalZ, false, false, false)
                SetEntityHeading(ghost, heading)
            end

            Draw3dLabel(base.x, base.y, finalZ + 0.3, ('Z: %.3f  H: %.1f°%s'):format(finalZ, heading, onGround and '  [On Ground]' or ''))

            DisableControlAction(0, 44,  true) -- Q
            DisableControlAction(0, 38,  true) -- E
            DisableControlAction(0, 47,  true) -- G
            DisableControlAction(0, 18,  true) -- ENTER
            DisableControlAction(0, 177, true) -- BACKSPACE
            DisableControlAction(0, 241, true) -- Scroll up
            DisableControlAction(0, 242, true) -- Scroll down

            if IsDisabledControlJustPressed(0, 44)  then heading = (heading - 5.0) % 360.0; onGround = false end
            if IsDisabledControlJustPressed(0, 38)  then heading = (heading + 5.0) % 360.0; onGround = false end
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
                isPlacing = false
                FinishPlacement(model, finalPos, heading)
                return
            end

            if IsDisabledControlJustPressed(0, 177) then
                TextUIHide()
                if DoesEntityExist(ghost) then DeleteObject(ghost) end
                SetModelAsNoLongerNeeded(hash)
                isPlacing = false
                Notify('Prop placer cancelled.', 'inform')
                return
            end

            Wait(0)
        end
    end)
end

-- ── Output ────────────────────────────────────────────────────────────────────

FinishPlacement = function(model, coords, heading)
    local vec3Code = ('vec3(%.2f, %.2f, %.2f)'):format(coords.x, coords.y, coords.z)
    local vec4Code = ('vec4(%.2f, %.2f, %.2f, %.2f)'):format(coords.x, coords.y, coords.z, heading)
    local code = ('%s\n    -- with heading: %s'):format(vec3Code, vec4Code)

    print(('\n%s\n[Restaurant Tools] Prop Placer — "%s":\n    Position only : %s\n    With heading  : %s\n%s\n')
        :format(('='):rep(60), model, vec3Code, vec4Code, ('='):rep(60)))

    TriggerServerEvent(ResourceEvent('propplacer:output'), model, code)

    lib.alertDialog({
        header   = 'Prop Placer — Done',
        content  = ('**Model:** `%s`  \n**Position:** `%s`  \n**With heading:** `%s`  \n\nAlso printed to **F8 console** and **server console**.'):format(model, vec3Code, vec4Code),
        centered = true,
        cancel   = false,
    })
end

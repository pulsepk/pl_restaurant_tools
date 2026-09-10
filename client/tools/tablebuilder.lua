-- ── Restaurant Tools — Table Builder ──────────────────────────────────────────
-- Command : /<Config.CommandPrefix>table  (set Config.CommandPrefix in shared/config.lua)
-- Access  : ace permission  pl_restaurant.locationbuilder
--
-- Flow:
--   1. Input dialog → name, label, icon, width, length, zone height,
--                     minZ/maxZ offsets, interaction type, job required
--   2. Place table centre — yellow box outline shows the exact footprint
--   3. Generate code → F8 + server console

local isBuildingTable = false
local TableBuilder

-- ── Permission ────────────────────────────────────────────────────────────────

RegisterCommand(Config.CommandPrefix .. 'table', function()
    if isBuildingTable then return end
    lib.callback(ResourceEvent('hasBuilderAccess'), false, function(ok)
        if not ok then
            Notify('You do not have permission to use the table builder.', 'error')
            return
        end
        TableBuilder.start()
    end)
end, false)

-- ── Helpers ───────────────────────────────────────────────────────────────────

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

-- Draws a yellow rectangle on the ground to visualise the table zone footprint.
local function DrawTableBox(cx, cy, cz, w, h, headingDeg)
    local hr  = math.rad(headingDeg)
    local fwx = -math.sin(hr);  local fwy = math.cos(hr)
    local rwx =  math.cos(hr);  local rwy = math.sin(hr)
    local hw, hh = w * 0.5, h * 0.5

    local ax, ay = cx + fwx * hh + rwx * hw, cy + fwy * hh + rwy * hw
    local bx, by = cx + fwx * hh - rwx * hw, cy + fwy * hh - rwy * hw
    local ccx, ccy = cx - fwx * hh - rwx * hw, cy - fwy * hh - rwy * hw
    local dx, dy = cx - fwx * hh + rwx * hw, cy - fwy * hh + rwy * hw

    DrawLine(ax, ay, cz, bx, by, cz, 255, 200, 0, 220)
    DrawLine(bx, by, cz, ccx, ccy, cz, 255, 200, 0, 220)
    DrawLine(ccx, ccy, cz, dx, dy, cz, 255, 200, 0, 220)
    DrawLine(dx, dy, cz, ax, ay, cz, 255, 200, 0, 220)
end

-- ── Placement ─────────────────────────────────────────────────────────────────

local CONE_MODEL = 'prop_mp_cone_01'

local function PlaceTablePoint(data, cb)
    local hash    = GetHashKey(CONE_MODEL)
    local heading = GetEntityHeading(PlayerPedId())
    local zAdjust = 0.0

    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 50 do Wait(100); t = t + 1 end

    local pt    = GetEntityCoords(PlayerPedId())
    local ghost = CreateObject(hash, pt.x, pt.y, pt.z, false, false, false)
    SetEntityAlpha(ghost, 160, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)

    local function showHint()
        TextUIShow(('Table  |  H: %.1f°  W: %.2f  L: %.2f  |  [ENTER] Confirm  [Scroll] Z ±0.05  [Q/E] Rotate ±5°  [←/→] W ±0.1  [↑/↓] L ±0.1  [BACKSPACE] Cancel'):format(heading, data.w, data.h), {
            position = 'left-center',
            icon     = 'fas fa-border-all',
        })
    end
    showHint()

    CreateThread(function()
        while true do
            local base   = GetGroundHit()
            local finalZ = base.z + zAdjust

            if DoesEntityExist(ghost) then
                SetEntityCoordsNoOffset(ghost, base.x, base.y, finalZ, false, false, false)
                SetEntityHeading(ghost, heading)
            end

            -- Yellow box outline shows the exact table footprint
            DrawTableBox(base.x, base.y, finalZ, data.w, data.h, heading)
            Draw3dLabel(base.x, base.y, finalZ + 0.6,
                ('Z: %.3f  H: %.1f°  W: %.2f  L: %.2f'):format(finalZ, heading, data.w, data.h))

            DisableControlAction(0, 44,  true)
            DisableControlAction(0, 38,  true)
            DisableControlAction(0, 18,  true)
            DisableControlAction(0, 177, true)
            DisableControlAction(0, 241, true)
            DisableControlAction(0, 242, true)
            DisableControlAction(0, 172, true)  -- Up arrow   → L +
            DisableControlAction(0, 173, true)  -- Down arrow → L -
            DisableControlAction(0, 174, true)  -- Left arrow → W -
            DisableControlAction(0, 175, true)  -- Right arrow→ W +

            if IsDisabledControlJustPressed(0, 44) then heading = (heading - 5.0) % 360.0; showHint() end
            if IsDisabledControlJustPressed(0, 38) then heading = (heading + 5.0) % 360.0; showHint() end
            if IsDisabledControlJustPressed(0, 241) then zAdjust = zAdjust + 0.05 end
            if IsDisabledControlJustPressed(0, 242) then zAdjust = zAdjust - 0.05 end
            if IsDisabledControlJustPressed(0, 175) then data.w = math.max(0.1, data.w + 0.1); showHint() end
            if IsDisabledControlJustPressed(0, 174) then data.w = math.max(0.1, data.w - 0.1); showHint() end
            if IsDisabledControlJustPressed(0, 172) then data.h = math.max(0.1, data.h + 0.1); showHint() end
            if IsDisabledControlJustPressed(0, 173) then data.h = math.max(0.1, data.h - 0.1); showHint() end

            if IsDisabledControlJustPressed(0, 18) then
                TextUIHide()
                if DoesEntityExist(ghost) then DeleteObject(ghost) end
                SetModelAsNoLongerNeeded(hash)
                cb(vector3(base.x, base.y, finalZ), heading)
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

-- ── Code generation ───────────────────────────────────────────────────────────

local function GenerateCode(data, coords, heading)
    local x  = ('%.2f'):format(coords.x)
    local y  = ('%.2f'):format(coords.y)
    local z  = ('%.2f'):format(coords.z)
    local h  = ('%.2f'):format(heading)
    local z0 = ('%.1f'):format(coords.z + data.minZOff)
    local z1 = ('%.1f'):format(coords.z + data.maxZOff)

    local lines = {
        '    {',
        ('        name         = %q,'):format(data.name),
        ('        TargetCoords = vector3(%s, %s, %s),'):format(x, y, z),
        ('        heading      = %s,'):format(h),
        ('        minZ         = %s,  maxZ   = %s,'):format(z0, z1),
        ('        w            = %s,  h      = %s,  height = %s,'):format(data.w, data.h, data.height),
        '',
        ('        Interaction  = %q,'):format(data.interaction),
        ('        icon         = %q,'):format(data.icon),
        ('        label        = %q,'):format(data.label),
        ('        jobRequired  = %s,'):format(data.jobRequired and 'true' or 'false'),
        '        onSelect     = function(entry) OpenStash(entry.name) end,',
        '    },',
    }
    return table.concat(lines, '\n')
end

-- ── Builder ───────────────────────────────────────────────────────────────────

local ICONS = {
    { value = 'fas fa-box',       label = 'Box'       },
    { value = 'fas fa-utensils',  label = 'Utensils'  },
    { value = 'fas fa-chair',     label = 'Chair'     },
    { value = 'fas fa-map-pin',   label = 'Map Pin'   },
    { value = 'fas fa-store',     label = 'Store'     },
    { value = 'fas fa-clipboard', label = 'Clipboard' },
}

TableBuilder = {
    start = function()
        isBuildingTable = true
        local input = lib.inputDialog('Table Builder', {
            { type = 'input',    label = 'Table Name',   placeholder = 'Cat Cafe Table 01', required = true  },
            { type = 'input',    label = 'Target Label', placeholder = 'Cat Cafe Table 01', required = true  },
            { type = 'select',   label = 'Icon',         options = ICONS, default = 'fas fa-box'             },
            { type = 'number',   label = 'Width  (w)',   default = 2.0,  min = 0.1, max = 20.0              },
            { type = 'number',   label = 'Length (h)',   default = 1.0,  min = 0.1, max = 20.0              },
            { type = 'number',   label = 'Zone Height',  default = 1.0,  min = 0.1, max = 5.0               },
            { type = 'number',   label = 'minZ offset',  default = -0.5, min = -5.0, max = 0.0              },
            { type = 'number',   label = 'maxZ offset',  default = 0.5,  min = 0.0,  max = 5.0              },
            { type = 'select',   label = 'Interaction',  options = {
                { value = 'target', label = 'Target (ox_target)' },
                { value = 'zone',   label = 'Zone (TextUI + E)'  },
            }, default = 'target' },
            { type = 'checkbox', label = 'Job Required', checked = false                                     },
        })

        if not input then
            isBuildingTable = false
            return
        end

        local data = {
            name        = tostring(input[1]),
            label       = tostring(input[2]),
            icon        = tostring(input[3]),
            w           = tonumber(input[4]) or 2.0,
            h           = tonumber(input[5]) or 1.0,
            height      = tonumber(input[6]) or 1.0,
            minZOff     = tonumber(input[7]) or -0.5,
            maxZOff     = tonumber(input[8]) or 0.5,
            interaction = tostring(input[9]),
            jobRequired = input[10] == true,
        }

        PlaceTablePoint(data, function(coords, heading)
            if not coords then
                isBuildingTable = false
                Notify('Table builder cancelled.', 'inform')
                return
            end

            local code = GenerateCode(data, coords, heading)

            print(('\n%s\n[Restaurant Tools] Table Builder — paste into Location.Tables in location.lua:\n%s\n%s\n')
                :format(('='):rep(60), code, ('='):rep(60)))

            TriggerServerEvent(ResourceEvent('tablebuilder:output'), code)

            isBuildingTable = false

            lib.alertDialog({
                header   = 'Table Builder — Done',
                content  = ('**Table:** `%s`  \n\nCode in **F8 console** and **server console**.\nPaste inside `Location.Tables = { ... }` in `location.lua`.'):format(data.name),
                centered = true,
                cancel   = false,
            })
        end)
    end,
}

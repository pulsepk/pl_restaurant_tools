
-- Command : /<Config.CommandPrefix>location  (set Config.CommandPrefix in shared/config.lua)
-- Access  : ace permission  pl_restaurant.locationbuilder
--
-- One combined tool: builds a full Location.Management entry AND its Stand
-- sub-table in a single pass, matching the format every branch's entries use
-- (e.g. gabz's HandWash/CustomerWash/Toilet — TargetCoords + prop for the
-- physical spot, plus a separate Stand = { coords, ZoneRadius, icon, label }
-- for where the player actually stands to trigger the interaction).
--
-- Interaction Type covers all three modes location.lua entries support:
-- target/zone/text3d (see shared/config.lua's Config.Interaction and the
-- ctn-text3d note there), plus a Force Sphere checkbox — same ForceSphere
-- flag used throughout location.lua to skip target-hover for small/thin
-- props, which text3d never needed to begin with.
--
-- Flow:
--   1. Input dialog  → name, prop, interaction, force sphere, label/icon,
--                       action, grade, job requirement, zone box size, stand
--                       zone radius
--   2. Place the object/box  → walk to the prop's spot, aim, ENTER to confirm
--   3. Place the Stand point → you're prompted to walk to where the PLAYER
--      should stand, then place a marker there (Z scroll, radius ring you can
--      resize live) — this can be a different spot than step 2
--   4. Generate code → F8 + server console, one complete entry ready to paste

local isBuilding      = false
local GHOST_MODEL      = 'prop_mp_cone_01'
local CONE_MODEL       = 'prop_mp_cone_01'
local OpenBuilderDialog
local PlaceObjectPoint
local PlaceStandPoint
local FinishPlacement

-- ── Permission ────────────────────────────────────────────────────────────────

RegisterCommand(Config.CommandPrefix .. 'location', function()
    if isBuilding then return end
    lib.callback(ResourceEvent('hasBuilderAccess'), false, function(ok)
        if not ok then
            Notify('You do not have permission to use the location builder.', 'error')
            return
        end
        OpenBuilderDialog()
    end)
end, false)

-- ── Dialog options ────────────────────────────────────────────────────────────

local ACTIONS = {
    { value = 'CategoryManage',   label = 'Management'          },
    { value = 'MakeCategoryMenu', label = 'Process (Crafting)'  },
    { value = 'ShopBossMenu',     label = 'Boss Menu'           },
    { value = 'OpenOrdersMenu',   label = 'Order Queue'         },
    { value = 'ClothMenu',        label = 'Clothing'            },
    { value = 'StashStorage',     label = 'Stash'               },
    { value = 'OpenIcecreamMenu', label = 'Ice Machine'         },
    { value = 'Duty',             label = 'Duty'                },
    { value = 'HandWash',         label = 'Hand Wash'           },
    { value = 'CustomerWash',     label = 'Customer Wash (public)' },
    { value = 'UseToilet',        label = 'Toilet (public)'     },
    { value = 'OpenShopKiosk',    label = 'Shop Kiosk (public)' },
    { value = 'custom',           label = 'Custom (fill later)' },
}

-- Common Location.Management entry names seen across the existing branches
-- (see shared/location.lua) — numbered instances (Counter 02, TrashCan 3,
-- etc.) still go through Custom, same as any name not listed here.
local ENTRY_NAMES = {
    { value = 'Management',     label = 'Management' },
    { value = 'Fridge',         label = 'Fridge' },
    { value = 'Process',        label = 'Process' },
    { value = 'KitchenOrders',  label = 'Order Queue' },
    { value = 'Stash',          label = 'Stash' },
    { value = 'BossMenu',       label = 'Boss Menu' },
    { value = 'Clothing',       label = 'Clothing' },
    { value = 'Duty',           label = 'Duty' },
    { value = 'HandWash',       label = 'Hand Wash' },
    { value = 'IceMachine',     label = 'Ice Machine' },
    { value = 'Counter',        label = 'Counter' },
    { value = 'BillingCounter', label = 'Billing Counter' },
    { value = 'Shop',           label = 'Shop / Kiosk' },
    { value = 'TrashCan',       label = 'Trash Can' },
    { value = 'PublicHandwash', label = 'Public Handwash' },
    { value = 'PublicToilet',   label = 'Public Toilet' },
    { value = 'custom',         label = 'Custom (type below)' },
}

-- value → display label, so picking an Entry Name can default Target Label
-- to the same human-readable text instead of making you type it twice.
local ENTRY_NAME_LABELS = {}
for _, e in ipairs(ENTRY_NAMES) do ENTRY_NAME_LABELS[e.value] = e.label end

-- Common prop models seen across the existing branches' Management/Grill/
-- Fryer/DrinkMachine entries.
local PROP_MODELS = {
    { value = 'prop_laptop_01a',      label = 'Laptop (prop_laptop_01a)' },
    { value = 'v_res_tre_fridge',     label = 'Fridge (v_res_tre_fridge)' },
    { value = 'pl_kiosk',             label = 'Kiosk (pl_kiosk)' },
    { value = 'prop_food_bin_02',     label = 'Trash Bin (prop_food_bin_02)' },
    { value = 'prop_bar_ice_01',      label = 'Ice Machine (prop_bar_ice_01)' },
    { value = 'prop_bbq_1',           label = 'BBQ / Grill (prop_bbq_1)' },
    { value = 'prop_chip_fryer',      label = 'Fryer (prop_chip_fryer)' },
    { value = 'prop_vend_colacan_01', label = 'Drink Machine (prop_vend_colacan_01)' },
    { value = 'custom',               label = 'Custom (type below)' },
}

local ICONS = {
    { value = 'fas fa-clipboard',     label = 'Clipboard'  },
    { value = 'fas fa-laptop',        label = 'Laptop'     },
    { value = 'fas fa-receipt',       label = 'Receipt'    },
    { value = 'fas fa-store',         label = 'Store'      },
    { value = 'fas fa-shirt',         label = 'Clothing'   },
    { value = 'fas fa-box',           label = 'Stash'      },
    { value = 'fas fa-ice-cream',     label = 'Ice Cream'  },
    { value = 'fas fa-hands-bubbles', label = 'Hand Wash'  },
    { value = 'fas fa-toilet',        label = 'Toilet'     },
    { value = 'fas fa-trash',         label = 'Trash'      },
    { value = 'fas fa-fire',          label = 'Grill/Fryer'},
    { value = 'fas fa-utensils',      label = 'Utensils'   },
    { value = 'fas fa-map-pin',       label = 'Map Pin'    },
}

-- ── Input dialog ──────────────────────────────────────────────────────────────

OpenBuilderDialog = function()
    local input = lib.inputDialog('Restaurant Tools — Location Builder', {
        { type = 'select',   label = 'Entry Name',       options = ENTRY_NAMES, default = 'Management' },
        { type = 'input',    label = 'Custom Entry Name', placeholder = 'e.g. Counter 05',   description = 'Only used if "Custom" is selected above' },
        { type = 'checkbox', label = 'Spawn a Prop?',    checked = false                                     },
        { type = 'select',   label = 'Prop Model',       options = PROP_MODELS, default = 'custom' },
        { type = 'input',    label = 'Custom Prop Model', placeholder = 'prop_laptop_01a',   description = 'Required when Spawn a Prop is checked and Prop Model above is "Custom"' },
        { type = 'select',   label = 'Interaction Type', options = {
                { value = '',       label = 'Use Global Default (Config.Interaction)' },
                { value = 'target', label = 'Target (ox_target)' },
                { value = 'zone',   label = 'Zone (TextUI + E)'  },
                { value = 'text3d', label = '3D Text (ctn-text3d)' },
            }, default = '' },
        { type = 'checkbox', label = 'Force Sphere?',    checked = false, description = 'Skip target-hover entirely (small/thin props ox_target/qb-target can\'t reliably hover) — forces Zone unless Interaction Type is 3D Text, which never needed target-hover anyway' },
        { type = 'input',    label = 'Target Label',     placeholder = 'My Station',        description = 'Leave blank to reuse the Entry Name\'s label above' },
        { type = 'select',   label = 'Icon',             options = ICONS,   default = 'fas fa-clipboard'     },
        { type = 'select',   label = 'Action',           options = ACTIONS, default = 'CategoryManage'       },
        { type = 'number',   label = 'Grade Requirement',default = 0,  min = 0,  max = 10                   },
        { type = 'checkbox', label = 'No Job Required (jobRequired = false)', checked = false, description = 'Anyone can interact, not just employees — check this for customer-facing spots (Customer Wash, Toilet, Shop Kiosk) as well as public counters' },
        { type = 'checkbox', label = 'Include TargetCoords Box?', checked = true, description = 'TargetCoords + minZ/maxZ/w/h/height for ox_target/qb-target box zones. Uncheck for a pure point/3D-text entry that doesn\'t need a box.' },
        { type = 'number',   label = 'Zone Width  (w)',  default = 0.5, min = 0.1, max = 20.0               },
        { type = 'number',   label = 'Zone Depth  (h)',  default = 0.6, min = 0.1, max = 20.0               },
        { type = 'number',   label = 'Zone Height',      default = 0.5, min = 0.1, max = 20.0               },
        { type = 'number',   label = 'Stand Zone Radius', default = 1.5, min = 0.3, max = 10.0, description = 'Radius of the Stand zone placed in step 3' },
    })

    if not input then return end

    local nameChoice = tostring(input[1])
    local name = (nameChoice == 'custom')
        and (type(input[2]) == 'string' and input[2]:match('^%s*(.-)%s*$') or '')
        or  nameChoice

    if name == '' then
        Notify('Entry name is required — pick one from the list, or choose Custom and type one.', 'error')
        return
    end

    local hasProp     = input[3] == true
    local modelChoice = tostring(input[4])
    local model = (modelChoice == 'custom')
        and (type(input[5]) == 'string' and input[5]:match('^%s*(.-)%s*$') or '')
        or  modelChoice

    if hasProp and model == '' then
        Notify('Prop model is required when Spawn a Prop is checked.', 'error')
        return
    end

    -- Defaults to the Entry Name's own display label when left blank — the
    -- two are usually the same text (e.g. "Fridge"/"Fridge"), so this only
    -- needs typing when they should actually differ (e.g. entry name
    -- "KitchenOrders" but label "Order Queue").
    local labelInput = type(input[8]) == 'string' and input[8]:match('^%s*(.-)%s*$') or ''
    local label = labelInput ~= '' and labelInput or (ENTRY_NAME_LABELS[nameChoice] or name)

    local data = {
        name          = name,
        hasProp       = hasProp,
        model         = hasProp and model or nil,
        interaction   = tostring(input[6]),
        forceSphere   = input[7] == true,
        label         = label,
        icon          = tostring(input[9]),
        action        = tostring(input[10]),
        grade         = tonumber(input[11]) or 0,
        public        = input[12] == true,
        includeBox    = input[13] == true,
        w             = tonumber(input[14]) or 0.5,
        h             = tonumber(input[15]) or 0.6,
        zoneH         = tonumber(input[16]) or 0.5,
        standRadius   = tonumber(input[17]) or 1.5,
    }

    PlaceObjectPoint(data)
end

-- ── Shared helpers ────────────────────────────────────────────────────────────

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

local function GetGroundHit()
    -- Same raycast as GetCameraGroundPoint; kept as a separate name to mirror
    -- the Stand-step semantics (walking + looking at the floor vs. placing an
    -- object out in front of the camera).
    return GetCameraGroundPoint()
end

local function LoadModel(hash)
    RequestModel(hash)
    local tries = 0
    while not HasModelLoaded(hash) and tries < 50 do
        Wait(100)
        tries = tries + 1
    end
    return HasModelLoaded(hash)
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

-- Draws a yellow ring on the ground so you can see exactly how big the Stand zone is.
local function DrawZoneCircle(cx, cy, cz, radius)
    local segments = 24
    local prevX, prevY
    for i = 0, segments do
        local a = (i / segments) * 2 * math.pi
        local px, py = cx + math.cos(a) * radius, cy + math.sin(a) * radius
        if prevX then
            DrawLine(prevX, prevY, cz, px, py, cz, 255, 200, 0, 200)
        end
        prevX, prevY = px, py
    end
end

-- ── Step 1: place the object/box (TargetCoords / ObjectCoords + heading) ─────

PlaceObjectPoint = function(data)
    isBuilding = true

    -- Use actual prop model as ghost so the player can see how it fits; fall back to cone
    local modelName = (data.hasProp and data.model) or GHOST_MODEL
    local modelHash = GetHashKey(modelName)

    if not LoadModel(modelHash) then
        modelHash = GetHashKey(GHOST_MODEL)
        LoadModel(modelHash)
    end

    local heading = GetEntityHeading(PlayerPedId())
    local origin  = GetEntityCoords(PlayerPedId())
    local ghost   = CreateObject(modelHash, origin.x, origin.y, origin.z, false, false, false)

    SetEntityAlpha(ghost, 150, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)

    local zAdjust = 0.0
    local onGround = false

    TextUIShow('Step 1/2: Object  |  [ENTER] Place  [Q] Rotate -5°  [E] Rotate +5°  [G] Snap to Ground  [BACKSPACE] Cancel', {
        position = 'left-center',
        icon     = 'fas fa-map-pin',
    })

    CreateThread(function()
        while isBuilding do
            local pt     = GetCameraGroundPoint()
            local finalZ = pt.z + zAdjust

            if DoesEntityExist(ghost) then
                SetEntityCoordsNoOffset(ghost, pt.x, pt.y, finalZ, false, false, false)
                SetEntityHeading(ghost, heading)
            end

            Draw3dLabel(pt.x, pt.y, finalZ + 0.3, ('Z: %.3f  H: %.1f°%s'):format(finalZ, heading, onGround and '  [On Ground]' or ''))

            DisableControlAction(0, 44,  true) -- Q
            DisableControlAction(0, 38,  true) -- E
            DisableControlAction(0, 47,  true) -- G
            DisableControlAction(0, 18,  true) -- ENTER
            DisableControlAction(0, 177, true) -- BACKSPACE

            if IsDisabledControlJustPressed(0, 44)  then heading = (heading - 5.0) % 360.0; onGround = false end
            if IsDisabledControlJustPressed(0, 38)  then heading = (heading + 5.0) % 360.0; onGround = false end

            if IsDisabledControlJustPressed(0, 47) and DoesEntityExist(ghost) then
                PlaceObjectOnGroundProperly(ghost)
                zAdjust  = GetEntityCoords(ghost).z - pt.z
                onGround = true
            end

            if IsDisabledControlJustPressed(0, 18) then
                local finalCoords = GetEntityCoords(ghost)
                TextUIHide()
                isBuilding = false
                DeleteObject(ghost)
                SetModelAsNoLongerNeeded(modelHash)

                lib.alertDialog({
                    header   = 'Object Placed',
                    content  = 'Now walk to where the **player should stand** to trigger the interaction, then press Enter to continue to step 2.',
                    centered = true,
                    cancel   = false,
                })

                PlaceStandPoint(data, finalCoords, heading)
                return
            end

            if IsDisabledControlJustPressed(0, 177) then
                TextUIHide()
                isBuilding = false
                DeleteObject(ghost)
                SetModelAsNoLongerNeeded(modelHash)
                Notify('Location builder cancelled.', 'inform')
                return
            end

            Wait(0)
        end
    end)
end

-- ── Step 2: place the Stand point (coords + live-adjustable radius) ─────────

PlaceStandPoint = function(data, objectCoords, objectHeading)
    isBuilding = true

    local hash     = GetHashKey(CONE_MODEL)
    local heading  = GetEntityHeading(PlayerPedId())
    local zAdjust  = 0.0
    local radius   = data.standRadius
    local onGround = false

    LoadModel(hash)

    local pt    = GetEntityCoords(PlayerPedId())
    local ghost = CreateObject(hash, pt.x, pt.y, pt.z, false, false, false)
    SetEntityAlpha(ghost, 160, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)

    local function showHint()
        TextUIShow(('Step 2/2: Stand Point  |  Radius: %.2f  |  [ENTER] Confirm  [Scroll] Z ±0.05  [Q/E] Rotate ±5°  [G] Snap to Ground  [↑/↓] Radius ±0.1  [BACKSPACE] Skip Stand'):format(radius), {
            position = 'left-center',
            icon     = 'fas fa-person-walking',
        })
    end
    showHint()

    CreateThread(function()
        while isBuilding do
            local base   = GetGroundHit()
            local finalZ = base.z + zAdjust

            if DoesEntityExist(ghost) then
                SetEntityCoordsNoOffset(ghost, base.x, base.y, finalZ, false, false, false)
                SetEntityHeading(ghost, heading)
            end

            DrawZoneCircle(base.x, base.y, finalZ, radius)
            Draw3dLabel(base.x, base.y, finalZ + 0.8,
                ('Z: %.3f  Radius: %.2f%s'):format(finalZ, radius, onGround and '  [On Ground]' or ''))

            DisableControlAction(0, 44,  true)  -- Q
            DisableControlAction(0, 38,  true)  -- E
            DisableControlAction(0, 47,  true)  -- G
            DisableControlAction(0, 18,  true)  -- ENTER
            DisableControlAction(0, 177, true)  -- BACKSPACE
            DisableControlAction(0, 241, true)  -- Scroll up
            DisableControlAction(0, 242, true)  -- Scroll down
            DisableControlAction(0, 172, true)  -- Up arrow   → radius +
            DisableControlAction(0, 173, true)  -- Down arrow → radius -

            if IsDisabledControlJustPressed(0, 44)  then heading = (heading - 5.0) % 360.0; onGround = false end
            if IsDisabledControlJustPressed(0, 38)  then heading = (heading + 5.0) % 360.0; onGround = false end
            if IsDisabledControlJustPressed(0, 241) then zAdjust = zAdjust + 0.05; onGround = false end
            if IsDisabledControlJustPressed(0, 242) then zAdjust = zAdjust - 0.05; onGround = false end
            if IsDisabledControlJustPressed(0, 172) then radius = math.min(10.0, radius + 0.1); showHint() end
            if IsDisabledControlJustPressed(0, 173) then radius = math.max(0.3,  radius - 0.1); showHint() end

            if IsDisabledControlJustPressed(0, 47) and DoesEntityExist(ghost) then
                PlaceObjectOnGroundProperly(ghost)
                zAdjust  = GetEntityCoords(ghost).z - base.z
                onGround = true
            end

            if IsDisabledControlJustPressed(0, 18) then
                local standCoords = vector3(base.x, base.y, finalZ)
                TextUIHide()
                isBuilding = false
                if DoesEntityExist(ghost) then DeleteObject(ghost) end
                SetModelAsNoLongerNeeded(hash)
                FinishPlacement(data, objectCoords, objectHeading, standCoords, radius)
                return
            end

            if IsDisabledControlJustPressed(0, 177) then
                TextUIHide()
                isBuilding = false
                if DoesEntityExist(ghost) then DeleteObject(ghost) end
                SetModelAsNoLongerNeeded(hash)
                Notify('Stand step skipped — generating the entry without a Stand table.', 'inform')
                FinishPlacement(data, objectCoords, objectHeading, nil, nil)
                return
            end

            Wait(0)
        end
    end)
end

-- ── Code generation ───────────────────────────────────────────────────────────

local function GenerateCode(data, coords, heading, standCoords, standRadius)
    local x  = ('%.2f'):format(coords.x)
    local y  = ('%.2f'):format(coords.y)
    local z  = ('%.2f'):format(coords.z)
    local h  = ('%.2f'):format(heading)
    -- minZ/maxZ for ox_target/qb-target box zones: minZ sits a small margin
    -- below TargetCoords.z (always < Z), maxZ is TargetCoords.z + the Zone
    -- Height you set above — matching how these are actually measured
    -- in-game (move/resize an ox_lib box zone around the object; the box's
    -- top is the target Z plus however tall the object is).
    local z0 = ('%.1f'):format(coords.z - 0.3)
    local z1 = ('%.1f'):format(coords.z + data.zoneH)

    -- `end` MUST come before the `--` comment — a line comment swallows
    -- everything after it on the same line, including an `end` keyword,
    -- which silently breaks the whole file below this point (never write
    -- `function() -- comment end`, only `function() end -- comment`).
    -- Billing Counter always routes to Order Queue in every existing branch —
    -- auto-forced here the same way Fridge auto-forces serverEvent below,
    -- regardless of whatever Action was picked in the dialog.
    local onSelect = data.name == 'BillingCounter'
        and 'function() OpenOrdersMenu() end'
        or  (data.action == 'custom'
            and 'function() end -- TODO: replace with your action'
            or  ('function() %s() end'):format(data.action))

    local lines = { '    {' }

    if data.hasProp then
        lines[#lines+1] = '        PropSpawn    = true,'
        lines[#lines+1] = ('        Model        = %q,'):format(data.model)
        lines[#lines+1] = ('        ObjectCoords = vec4(%s, %s, %s, %s),'):format(x, y, z, h)
        lines[#lines+1] = ''
    else
        lines[#lines+1] = '        PropSpawn    = false,'
    end

    lines[#lines+1] = ('        name         = prefix .. %q,'):format(data.name)

    if data.includeBox then
        lines[#lines+1] = ('        TargetCoords = vector3(%s, %s, %s),'):format(x, y, z)
        lines[#lines+1] = ('        heading      = %s,'):format(h)
        lines[#lines+1] = ('        minZ         = %s,  maxZ   = %s,'):format(z0, z1)
        lines[#lines+1] = ('        w            = %s,  h      = %s,  height = %s,'):format(data.w, data.h, data.zoneH)
        lines[#lines+1] = ''
    end

    if data.interaction ~= '' then
        lines[#lines+1] = ('        Interaction  = %q,'):format(data.interaction)
    end

    if data.forceSphere then
        lines[#lines+1] = '        ForceSphere  = true,'
    end

    -- The shop kiosk is discovered at startup via Location.BuyMenu scanning for
    -- shopZone = true (see the bottom of each branch in location.lua).
    if data.action == 'OpenShopKiosk' then
        lines[#lines+1] = '        shopZone     = true,'
    end

    lines[#lines+1] = ('        icon         = %q,'):format(data.icon)
    lines[#lines+1] = ('        label        = %q,'):format(data.label)

    if data.grade > 0 then
        lines[#lines+1] = ('        grade        = %d,'):format(data.grade)
    end

    -- No auto-force here (e.g. for OpenShopKiosk) — jobRequired is purely
    -- driven by the checkbox so the generated code always matches what you
    -- actually asked for. A kiosk left job-gated by accident is caught below
    -- instead, via a build-time warning rather than a silent override.
    if data.public then
        lines[#lines+1] = '        jobRequired  = false,'
    end

    -- Fridge entries don't use onSelect anywhere in location.lua — the
    -- click routes straight to the server, which responds by opening the
    -- Fridge UI (see server/unlocked.lua's getStock handler).
    if data.name == 'Fridge' then
        lines[#lines+1] = "        serverEvent  = ResourceEvent('getStock'),"
    else
        lines[#lines+1] = ('        onSelect     = %s,'):format(onSelect)
    end

    if standCoords then
        local sx = ('%.2f'):format(standCoords.x)
        local sy = ('%.2f'):format(standCoords.y)
        -- +1: the raycast places the marker at floor level, but every existing
        -- Stand.coords in location.lua was recorded from GetEntityCoords(ped)
        -- while standing there, which sits ~1 unit above the actual ground —
        -- matching that here keeps generated entries consistent with the rest.
        local sz = ('%.2f'):format(standCoords.z + 1)
        local sr = ('%.2f'):format(standRadius)
        lines[#lines+1] = ('        Stand        = { coords = vec3(%s, %s, %s), ZoneRadius = %s, icon = %q, label = %q },'):format(
            sx, sy, sz, sr, data.icon, data.label)
    end

    lines[#lines+1] = '    },'

    return table.concat(lines, '\n')
end

-- ── Output ────────────────────────────────────────────────────────────────────

FinishPlacement = function(data, coords, heading, standCoords, standRadius)
    local code = GenerateCode(data, coords, heading, standCoords, standRadius)

    if data.action == 'OpenShopKiosk' and not data.public then
        Notify('Shop Kiosk entries are normally public — you left "No Job Required" unchecked, so this one will be job-gated.', 'warning')
    end

    print(('\n%s\n[Restaurant Tools] Location Builder — paste into Location.Management in location.lua:\n%s\n%s\n')
        :format(('='):rep(60), code, ('='):rep(60)))

    TriggerServerEvent(ResourceEvent('locationbuilder:output'), code)

    local standLine = standCoords
        and ('**Stand:** `%s, %s, %s` (radius `%s`)'):format(
                -- +1 on Z to match what GenerateCode actually wrote — see the
                -- comment there.
                ('%.2f'):format(standCoords.x), ('%.2f'):format(standCoords.y), ('%.2f'):format(standCoords.z + 1),
                ('%.2f'):format(standRadius))
        or  '**Stand:** skipped'

    lib.alertDialog({
        header  = 'Location Builder — Done',
        content = ('**Entry:** `%s`  \n**Target Label:** `%s`  \n**Coords:** `%s, %s, %s`  \n**Heading:** `%s`  \n%s  \n\nFull code is in your **F8 console** and the **server console**.\nPaste it inside `Location.Management = { ... }` in `location.lua`.'):format(
            data.name,
            data.label,
            ('%.2f'):format(coords.x), ('%.2f'):format(coords.y), ('%.2f'):format(coords.z),
            ('%.2f'):format(heading),
            standLine
        ),
        centered = true,
        cancel   = false,
    })
end

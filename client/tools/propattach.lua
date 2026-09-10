-- ── Restaurant Tools — Prop Attachment Offset Tool ───────────────────────────
-- Command : /<Config.CommandPrefix>attach  (set Config.CommandPrefix in shared/config.lua)
-- Access  : ace permission  pl_restaurant.locationbuilder
--
-- For tuning rpemotes-style PropPlacement offsets ({x, y, z, rx, ry, rz}
-- relative to a ped bone) — rpemotes itself has no interactive tool for this,
-- it's just static data fed straight into AttachEntityToEntity every time an
-- emote plays (see rpemotes/client/Emote.lua:337-350). This attaches the prop
-- live to YOUR OWN ped at the chosen bone so you see exactly how it'll look,
-- lets you nudge all 6 values into place, and prints the PropPlacement table
-- ready to paste into AnimationList.lua.
--
-- Also supports a two-link chain (Parent Prop): e.g. tuning where a patty
-- sits relative to a spatula that's already correctly placed in the hand,
-- rather than only ever tuning things relative to the ped bone directly.
-- [C] switches which of the two (parent or child) the controls affect.
--
-- Drives the native DrawGizmo widget (0xEB2EDCA2) directly — the same one the
-- object_gizmo resource uses — instead of depending on that resource being
-- installed/running. Cross-resource export calls to it kept producing wrong,
-- hard-to-debug conversions (world<->bone-local timing/ordering issues), so
-- everything now runs in one self-contained loop we fully control.
--
-- Flow:
--   1. Input dialog → prop model (dropdown/custom), bone (dropdown/custom),
--      offsets pasted as a single 6-number block (paste an AnimationList.lua
--      PropPlacement array straight in), optional Parent Prop, optional
--      walkable preview animation.
--   2. [C] switches between editing the Parent Prop's offset (relative to
--      the bone) and the main Prop's offset (relative to the Parent, or the
--      bone if no Parent is set). Only relevant when a Parent Prop is set.
--   3. [G] toggles Gizmo Mode: mouse-drag translate/rotate handles move the
--      currently-active prop freely in world space (rotate is [R], built into
--      the game's own gizmo commands). When you leave Gizmo Mode (or confirm
--      while still in it), the target world position AND rotation are each
--      converted to a bone/parent-relative offset by EMPIRICAL CALIBRATION —
--      attaching a hidden reference prop at tiny test offsets via the real
--      AttachEntityToEntity call, measuring where/how each actually lands,
--      and solving the resulting 3x3 linear system for the exact offset that
--      reproduces the target. This only trusts the same attach call already
--      proven correct — no second native's coordinate convention is assumed.
--   4. With Gizmo Mode off: [Arrows] move X/Y, [Scroll] moves Z, [Q/E] rotate
--      yaw (Z), [Shift+Arrows] rotate pitch (X) / roll (Y) — live attached
--      preview, guaranteed 1:1 accurate (same AttachEntityToEntity call
--      rpemotes makes). [ENTER] confirms, [BACKSPACE] cancels.
--   5. Offset(s) printed to F8 + server console.

local dataview = require 'client.tools.dataview'

local isPlacing = false
local ModelChoice
local StartAttach
local FinishAttach

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

-- ── Permission gate ───────────────────────────────────────────────────────────

RegisterCommand(Config.CommandPrefix .. 'attach', function()
    if isPlacing then return end
    lib.callback(ResourceEvent('hasBuilderAccess'), false, function(ok)
        if not ok then
            Notify('You do not have permission to use the prop attachment tool.', 'error')
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
    { value = 'pl_fry_basket',     label = 'Fry Basket (pl_fry_basket)' },
    { value = 'custom',            label = 'Custom (type below)' },
}

local BONES = {
    { value = '28422', label = 'Right Hand (28422)' },
    { value = '18905', label = 'Left Hand (18905)' },
    { value = '60309', label = 'Right Hand — physics (60309)' },
    { value = '57005', label = 'Left Hand — physics (57005)' },
    { value = '0',     label = 'Root / Pelvis (0)' },
    { value = 'custom', label = 'Custom (type below)' },
}

-- Parses a pasted PropPlacement-style block — e.g.
--   0.15,
--   0.00,
--   -0.03,
--   -91.079,
--   95.026,
--   -9.305,
-- (arbitrary whitespace/indentation/newlines, trailing commas) — takes the
-- first 6 numeric tokens found, in order, as x/y/z/rx/ry/rz.
local function ParseSixNumbers(text)
    if type(text) ~= 'string' then return nil end
    local nums = {}
    for numStr in text:gmatch('%-?%d+%.?%d*') do
        nums[#nums + 1] = tonumber(numStr)
        if #nums == 6 then break end
    end
    if #nums < 6 then return nil end
    return { x = nums[1], y = nums[2], z = nums[3], rx = nums[4], ry = nums[5], rz = nums[6] }
end

local function FormatBlock(o)
    return ('%s,\n%s,\n%s,\n%s,\n%s,\n%s,'):format(o.x, o.y, o.z, o.rx, o.ry, o.rz)
end

-- Standalone defaults for the "Parent Prop" fields — a spatula-in-hand offset
-- that's a reasonable generic starting point for prop-on-hand tuning. This
-- tool has no config of its own to pull a "current tune" from (it's meant to
-- be reused across different restaurant resources), so these are plain
-- literals rather than looked up from any specific resource's config.
local function DefaultParent()
    return {
        model = 'prop_fish_slice_01',
        o     = { x = 0.15, y = 0.00, z = -0.03, rx = -91.079, ry = 95.026, rz = -9.305 },
    }
end

-- Same idea for the animation default — kitchen_spatula is just a reasonable
-- generic "holding something in the hand" pose to preview against.
local function DefaultAnim()
    return {
        dict = 'kitchen_spatula',
        clip = 'kitchen_spatula',
    }
end

ModelChoice = function()
    local dp = DefaultParent()
    local da = DefaultAnim()
    local input = lib.inputDialog('Prop Attachment Tool', {
        { type = 'select',   label = 'Prop Model',        options = MODELS, default = 'pl_fry_basket' },
        { type = 'input',    label = 'Custom Model Name', placeholder = 'e.g. prop_cs_burger_01', description = 'Only used if "Custom" is selected above' },
        { type = 'select',   label = 'Bone',              options = BONES, default = '28422' },
        { type = 'input',    label = 'Custom Bone ID',    placeholder = 'e.g. 28422', description = 'Only used if "Custom" is selected above' },
        { type = 'input',    label = 'Parent Prop Model (optional)', default = '', placeholder = 'e.g. ' .. dp.model,
          description = 'Leave blank to attach the Prop Model directly to the bone. Fill in to attach a HELD prop to the bone instead (e.g. a spatula), with the Prop Model then tuned relative to IT (e.g. a patty on the spatula) — [C] switches which one the controls affect.' },
        { type = 'textarea', label = 'Bone Offset',       default = FormatBlock({ x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0 }),
          description = 'Paste 6 numbers (x, y, z, rx, ry, rz) — e.g. an existing PropPlacement, one per line or comma-separated. This is whatever attaches DIRECTLY to the bone: the Parent Prop\'s offset if one is set above, otherwise the Prop Model\'s own starting offset. Starts neutral (all zero) — paste an existing tuned offset here if you\'re resuming a tune, e.g. ' .. FormatBlock(dp.o):gsub('\n', ' ') },
        { type = 'textarea', label = 'Child Offset (optional)', placeholder = 'Paste 6 numbers — only used if a Parent Prop Model is set above. Leave blank to start the child neutral (0,0,0) and tune it from scratch in-tool.',
          description = 'Seeds the Prop Model\'s offset relative to the Parent Prop, e.g. resuming a patty-on-spatula offset you already tuned instead of starting over.' },
        { type = 'input',    label = 'Position Step (optional)', placeholder = 'Leave blank for default (0.10)', description = 'How far Arrows/Scroll move the active prop per press' },
        { type = 'input',    label = 'Rotation Step (optional)', placeholder = 'Leave blank for default (1.0)',  description = 'How many degrees Q/E/Shift+Arrows rotate the active prop per press' },
        { type = 'input',    label = 'Animation Dict (optional)', default = '', placeholder = 'e.g. ' .. da.dict,
          description = 'Plays a looping, walkable animation on you for the whole session (same as the real carry emote) so what you see here matches the actual held pose. Leave blank for no animation.' },
        { type = 'input',    label = 'Animation Clip (optional)', default = '', placeholder = 'e.g. ' .. da.clip },
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

    local boneSel = tostring(input[3])
    local boneId
    if boneSel == 'custom' then
        boneId = tonumber(input[4])
        if not boneId then
            Notify('Enter a valid numeric bone ID.', 'error')
            return
        end
    else
        boneId = tonumber(boneSel)
    end

    local parentModel = type(input[5]) == 'string' and input[5]:match('^%s*(.-)%s*$') or ''
    local boneOffset  = ParseSixNumbers(input[6])
    local childOffset = ParseSixNumbers(input[7])

    local parent, startOff
    if parentModel ~= '' then
        -- Bone Offset seeds the PARENT (e.g. the spatula). Child Offset (if
        -- given) seeds the main prop's offset relative to it — e.g. resuming
        -- a patty-on-spatula tune instead of starting over; leave it blank to
        -- start the child neutral (0,0,0) as before.
        parent = { model = parentModel, offset = boneOffset or dp.o }
        startOff = childOffset or {}
    else
        -- No parent — Bone Offset seeds the main prop directly, same as the
        -- old "Start Offset" field. Child Offset is ignored in this case.
        startOff = boneOffset or {}
    end

    local posStep = tonumber(input[8])
    local rotStep = tonumber(input[9])

    local anim = nil
    local animDict = type(input[10]) == 'string' and input[10]:match('^%s*(.-)%s*$') or ''
    local animClip = type(input[11]) == 'string' and input[11]:match('^%s*(.-)%s*$') or ''
    if animDict ~= '' and animClip ~= '' then
        anim = { dict = animDict, clip = animClip }
    end

    StartAttach(model, boneId, startOff, parent, anim, posStep, rotStep)
end

-- ── Attach params (must exactly match rpemotes' addProp — Emote.lua:320-321) ───

local ATTACH_FLAGS = { true, true, false, true, 1, true } -- useSoftPinning, collision, isPed, vertexIndex, fixedRot, p14
local DEFAULT_ROT  = { rx = 0.0, ry = -0.0, rz = -179.96 }

local function AttachLikeRpemotes(entity, parentEntity, boneIdx, x, y, z, rx, ry, rz)
    AttachEntityToEntity(entity, parentEntity, boneIdx, x, y, z, rx, ry, rz,
        ATTACH_FLAGS[1], ATTACH_FLAGS[2], ATTACH_FLAGS[3], ATTACH_FLAGS[4], ATTACH_FLAGS[5], ATTACH_FLAGS[6])
end

-- Solves x*a + y*b + z*c = d for x,y,z via Cramer's rule (exact regardless of
-- whether a/b/c are orthogonal — no assumption about the native's axis
-- convention needed, only that the mapping is linear, which it is).
local function Solve3x3(a, b, c, d)
    local function det(m11, m12, m13, m21, m22, m23, m31, m32, m33)
        return m11 * (m22 * m33 - m23 * m32) - m12 * (m21 * m33 - m23 * m31) + m13 * (m21 * m32 - m22 * m31)
    end
    local D = det(a.x, b.x, c.x, a.y, b.y, c.y, a.z, b.z, c.z)
    if D == 0 then return 0.0, 0.0, 0.0 end
    local Dx = det(d.x, b.x, c.x, d.y, b.y, c.y, d.z, b.z, c.z)
    local Dy = det(a.x, d.x, c.x, a.y, d.y, c.y, a.z, d.z, c.z)
    local Dz = det(a.x, b.x, d.x, a.y, b.y, d.y, a.z, b.z, d.z)
    return Dx / D, Dy / D, Dz / D
end

-- Quaternion helpers for calibrateRotation() below — rotation, unlike position,
-- isn't a linear function of (rx, ry, rz) in general, so Solve3x3 can't be
-- applied to raw Euler angles directly. Instead each test perturbation's
-- resulting world rotation is converted to a small delta rotation FROM the
-- base rotation (quatMul(measured, conjugate(base))), which for a small EPS is
-- ~linear in the rotation-vector (axis * angle) sense — that vector IS what
-- Solve3x3 solves for, same trick as the position calibration, just one layer
-- of quaternion math added to get into a linear space first.
local function quatMul(a, b)
    return {
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
end

local function quatConj(q)
    return { x = -q.x, y = -q.y, z = -q.z, w = q.w }
end

-- Quaternion logarithm → rotation vector (axis * angle, in degrees). Exact for
-- any angle, but calibrateRotation() only ever feeds this small delta
-- quaternions (a few degrees), where the axis is well-defined and the result
-- behaves linearly enough for Solve3x3.
local function quatToRotVec(q)
    local w = math.max(-1.0, math.min(1.0, q.w))
    local angle = 2.0 * math.acos(w)
    local s = math.sqrt(math.max(0.0, 1.0 - w * w))
    if s < 0.0001 then return { x = 0.0, y = 0.0, z = 0.0 } end
    local deg = angle * (180.0 / math.pi)
    return { x = q.x / s * deg, y = q.y / s * deg, z = q.z / s * deg }
end

-- ── Gizmo widget helpers (adapted from object_gizmo/client/gizmo.lua) ──────────

local function normalize(x, y, z)
    local length = math.sqrt(x * x + y * y + z * z)
    if length == 0 then return 0, 0, 0 end
    return x / length, y / length, z / length
end

local function makeEntityMatrix(entity)
    local f, r, u, a = GetEntityMatrix(entity)
    local view = dataview.ArrayBuffer(60)

    view:SetFloat32(0, r[1]):SetFloat32(4, r[2]):SetFloat32(8, r[3]):SetFloat32(12, 0)
        :SetFloat32(16, f[1]):SetFloat32(20, f[2]):SetFloat32(24, f[3]):SetFloat32(28, 0)
        :SetFloat32(32, u[1]):SetFloat32(36, u[2]):SetFloat32(40, u[3]):SetFloat32(44, 0)
        :SetFloat32(48, a[1]):SetFloat32(52, a[2]):SetFloat32(56, a[3]):SetFloat32(60, 1)

    return view
end

local function applyEntityMatrix(entity, view)
    local x1, y1, z1 = view:GetFloat32(16), view:GetFloat32(20), view:GetFloat32(24)
    local x2, y2, z2 = view:GetFloat32(0),  view:GetFloat32(4),  view:GetFloat32(8)
    local x3, y3, z3 = view:GetFloat32(32), view:GetFloat32(36), view:GetFloat32(40)
    local tx, ty, tz = view:GetFloat32(48), view:GetFloat32(52), view:GetFloat32(56)

    x1, y1, z1 = normalize(x1, y1, z1)
    x2, y2, z2 = normalize(x2, y2, z2)
    x3, y3, z3 = normalize(x3, y3, z3)

    SetEntityMatrix(entity, x1, y1, z1, x2, y2, z2, x3, y3, z3, tx, ty, tz)
end

-- ── Main tool ────────────────────────────────────────────────────────────────

local DEFAULT_POS_STEP = 0.10
local DEFAULT_ROT_STEP = 1.0

-- Controls: 172/173/174/175 = Arrow Up/Down/Left/Right, 21 = Shift, 47 = G,
-- 44/38 = Q/E, 241/242 = Scroll Up/Down, 24/25 = LMB/RMB (needed for gizmo
-- handle dragging). Confirm/Cancel/Switch-Prop are NOT read via raw control
-- IDs — control 18 (INPUT_FRONTEND_ACCEPT) is also bound to left-click in
-- many contexts, so clicking a gizmo handle was falsely triggering "confirm".
-- Using lib.addKeybind with an explicit key name instead, same as gizmo.lua
-- does for its own RETURN binding.
local CONTROLS = { 172, 173, 174, 175, 21, 47, 44, 38, 241, 242, 24, 25 }

-- Movement/melee controls to suppress for the whole tool session so the ped
-- doesn't wander off or throw a punch while you're mid-edit: 30/31 = analog
-- move, 32-35 = WASD, 36 = duck, 22 = jump, 140-143 = melee light/heavy/alt/block
-- (140 is also GTA's default "R" melee-attack binding when unarmed — disabling
-- it is what stops R from throwing a punch; gizmo.lua does the same).
-- These are disabled UNCONDITIONALLY, including in Gizmo Mode: DisableControlAction
-- operates on the classic control layer, while the W/R mode-switch keybinds below
-- use ox_lib's separate RegisterKeyMapping-based layer, so the two don't conflict.
local BLOCKED_CONTROLS = { 30, 31, 32, 33, 34, 35, 36, 22, 140, 141, 142, 143 }

local confirmRequested = false
local cancelRequested  = false
local switchRequested  = false
local gizmoActive      = false

lib.addKeybind({
    name        = 'pl_restauranttools_propattach_confirm',
    description = 'Confirm prop attachment offset',
    defaultKey  = 'RETURN',
    onReleased  = function()
        if not isPlacing then return end
        confirmRequested = true
    end,
})

lib.addKeybind({
    name        = 'pl_restauranttools_propattach_cancel',
    description = 'Cancel prop attachment tool',
    defaultKey  = 'BACK',
    onReleased  = function()
        if not isPlacing then return end
        cancelRequested = true
    end,
})

lib.addKeybind({
    name        = 'pl_restauranttools_propattach_switch',
    description = 'Switch between editing the Parent Prop and the Child Prop',
    defaultKey  = 'C',
    onReleased  = function()
        if not isPlacing then return end
        switchRequested = true
    end,
})

-- Gizmo mode-switch: the widget listens for these +/- commands, not the raw
-- W/R keys directly (that's why blocking control 32/140 above doesn't stop
-- these from working — separate input layers).
lib.addKeybind({
    name        = 'pl_restauranttools_propattach_translate',
    description = 'Gizmo: translate mode',
    defaultKey  = 'W',
    onPressed   = function()
        if not isPlacing or not gizmoActive then return end
        ExecuteCommand('+gizmoTranslation')
    end,
    onReleased  = function()
        if not isPlacing or not gizmoActive then return end
        ExecuteCommand('-gizmoTranslation')
    end,
})

-- No Rotate-mode keybind registered here — but [R] still switches the widget
-- into rotate mode regardless, since '+gizmoRotation'/'-gizmoRotation' are
-- built into the game's own DrawGizmo command set (object_gizmo's gizmo.lua
-- just adds a keybind that calls the same pre-existing commands, it doesn't
-- invent them), so it can't be suppressed from here the way a resource-owned
-- keybind could. That used to be a real bug: calibrateOffset() only ever
-- solved for position, so any rotation applied via the widget looked like it
-- worked while dragging, then got silently discarded on exit (reverting to
-- the old rx/ry/rz) — the prop visibly "jumping" the instant Gizmo Mode ended.
-- calibrateRotation() (below, alongside calibrateOffset()) now empirically
-- solves for rotation too, so dragging with [R]'s rotate handles is fully
-- supported. The keyboard Q/E/Shift+Arrows controls remain available as a
-- non-gizmo alternative either way.

StartAttach = function(model, boneId, startOff, parent, anim, posStep, rotStep)
    isPlacing = true
    confirmRequested = false
    cancelRequested  = false
    switchRequested  = false
    gizmoActive      = false

    -- Shadow the module-level defaults for this session only, if overridden.
    local POS_STEP = posStep or DEFAULT_POS_STEP
    local ROT_STEP = rotStep or DEFAULT_ROT_STEP

    local hash = GetHashKey(model)
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) and t < 100 do Wait(100); t = t + 1 end

    if not HasModelLoaded(hash) then
        isPlacing = false
        Notify(('Model "%s" failed to load — check the name.'):format(model), 'error')
        return
    end

    local ped = PlayerPedId()
    local boneIdx = GetPedBoneIndex(ped, boneId)
    local pedCoords = GetEntityCoords(ped)

    -- Optional looping, walkable animation (flag 49 — same convention as most
    -- restaurant carry systems' own emote handling) so the hand bone is posed
    -- exactly how it'll actually look during the real carry emote, not idle stance.
    if anim then
        LoadAnimDict(anim.dict)
        TaskPlayAnim(ped, anim.dict, anim.clip, 8.0, 8.0, -1, 49, 0, false, false, false)
    end

    -- If a Parent Prop was given, spawn+attach it to the ped. Both this and
    -- the main prop's offsets are live-adjustable — [C] picks which one.
    local parentProp = nil
    local parentOff = nil
    if parent then
        local parentHash = GetHashKey(parent.model)
        RequestModel(parentHash)
        local pt = 0
        while not HasModelLoaded(parentHash) and pt < 100 do Wait(100); pt = pt + 1 end
        if not HasModelLoaded(parentHash) then
            isPlacing = false
            Notify(('Parent model "%s" failed to load — check the name.'):format(parent.model), 'error')
            return
        end
        parentProp = CreateObject(parentHash, pedCoords.x, pedCoords.y, pedCoords.z, false, true, false)
        SetEntityAsMissionEntity(parentProp, true, true)
        SetEntityCollision(parentProp, false, false)
        SetModelAsNoLongerNeeded(parentHash)
        parentOff = {
            x = parent.offset.x, y = parent.offset.y, z = parent.offset.z,
            rx = parent.offset.rx, ry = parent.offset.ry, rz = parent.offset.rz,
        }
        AttachLikeRpemotes(parentProp, ped, boneIdx, parentOff.x, parentOff.y, parentOff.z, parentOff.rx, parentOff.ry, parentOff.rz)
    end

    local editingParent = false -- which offset [C]/keyboard/gizmo currently affect; only relevant if parent ~= nil

    -- All props below are created LOCAL (isNetwork=false) — this tool is only
    -- ever seen by the person running it, so there's no reason to pay for
    -- network sync, and doing so actively broke calibrateOffset(): a networked
    -- entity's transform can lag a few frames behind its own AttachEntityToEntity
    -- call before GetEntityCoords reflects it, which corrupted refProp's 4
    -- rapid-fire test-offset measurements (10 frames apart) and produced a
    -- consistently wrong solved offset — visible as the prop "jumping" the
    -- instant you left Gizmo Mode and it reattached at that bad offset.

    -- Hidden reference prop, reused as the measuring instrument for
    -- calibrateOffset() below.
    local refProp = CreateObject(hash, pedCoords.x, pedCoords.y, pedCoords.z, false, true, false)
    SetEntityAsMissionEntity(refProp, true, true)
    SetEntityCollision(refProp, false, false)
    SetEntityVisible(refProp, false, false)

    local prop = CreateObject(hash, pedCoords.x, pedCoords.y, pedCoords.z, false, true, false)
    SetEntityAsMissionEntity(prop, true, true)
    SetEntityCollision(prop, false, false)

    -- The -179.96-degree seed only made sense for direct ped-bone attachment
    -- (rpemotes' own default). No equivalent reference exists for prop-on-prop,
    -- so start neutral there and let the keyboard controls find the real value.
    local seedRot = parent and { rx = 0.0, ry = 0.0, rz = 0.0 } or DEFAULT_ROT

    local childOff = {
        x  = startOff.x  or 0.0,
        y  = startOff.y  or 0.0,
        z  = startOff.z  or 0.0,
        rx = startOff.rx or seedRot.rx,
        ry = startOff.ry or seedRot.ry,
        rz = startOff.rz or seedRot.rz,
    }
    AttachLikeRpemotes(prop, parent and parentProp or ped, parent and 0 or boneIdx,
        childOff.x, childOff.y, childOff.z, childOff.rx, childOff.ry, childOff.rz)

    -- Whichever is currently being tuned: the offset table, the entity being
    -- previewed/dragged, and the (entity, boneIdx) that offset is relative to.
    local function Active()
        if parent and editingParent then
            return parentOff, parentProp, ped, boneIdx
        end
        return childOff, prop, (parent and parentProp or ped), (parent and 0 or boneIdx)
    end

    -- Empirically calibrates against the REAL AttachEntityToEntity call: attaches
    -- the hidden refProp at three tiny test offsets, measures where each actually
    -- lands, and solves the exact offset that reproduces targetWorldPos. Only
    -- ~10 frames per measurement (settle time), refProp is invisible so this is
    -- not seen. calibEntity/calibBoneIdx/activeOff are passed in fresh each call
    -- since [C] can change what "relative to" means between calibrations.
    local function calibrateOffset(targetWorldPos, calibEntity, calibBoneIdx, activeOff)
        local EPS = 0.25
        local function measure(x, y, z)
            AttachLikeRpemotes(refProp, calibEntity, calibBoneIdx, x, y, z, activeOff.rx, activeOff.ry, activeOff.rz)
            for _ = 1, 10 do Wait(0) end
            return GetEntityCoords(refProp)
        end

        local basePos = measure(0.0, 0.0, 0.0)
        local xPos    = measure(EPS, 0.0, 0.0)
        local yPos    = measure(0.0, EPS, 0.0)
        local zPos    = measure(0.0, 0.0, EPS)

        local xAxis = { x = (xPos.x - basePos.x) / EPS, y = (xPos.y - basePos.y) / EPS, z = (xPos.z - basePos.z) / EPS }
        local yAxis = { x = (yPos.x - basePos.x) / EPS, y = (yPos.y - basePos.y) / EPS, z = (yPos.z - basePos.z) / EPS }
        local zAxis = { x = (zPos.x - basePos.x) / EPS, y = (zPos.y - basePos.y) / EPS, z = (zPos.z - basePos.z) / EPS }
        local delta = { x = targetWorldPos.x - basePos.x, y = targetWorldPos.y - basePos.y, z = targetWorldPos.z - basePos.z }

        return Solve3x3(xAxis, yAxis, zAxis, delta)
    end

    -- Same empirical philosophy as calibrateOffset(), extended to rotation.
    -- The gizmo widget lets you free-rotate the prop (see the note above the
    -- BLOCKED_CONTROLS declaration — [R] switches the widget into rotate mode
    -- via a keybind baked into the game itself, not one this tool registers,
    -- so it can't simply be suppressed), and previously the resulting rotation
    -- was silently discarded on exit, reverting to whatever rx/ry/rz existed
    -- before Gizmo Mode — this reproduces the target rotation instead.
    local function calibrateRotation(targetWorldRot, calibEntity, calibBoneIdx, activeOff)
        local EPS = 2.0 -- degrees
        local function measure(rx, ry, rz)
            AttachLikeRpemotes(refProp, calibEntity, calibBoneIdx, activeOff.x, activeOff.y, activeOff.z, rx, ry, rz)
            for _ = 1, 10 do Wait(0) end
            local x, y, z, w = GetEntityQuaternion(refProp)
            return { x = x, y = y, z = z, w = w }
        end

        local base     = measure(activeOff.rx, activeOff.ry, activeOff.rz)
        local baseConj = quatConj(base)
        local function deltaFromBase(q) return quatToRotVec(quatMul(q, baseConj)) end

        local xVec = deltaFromBase(measure(activeOff.rx + EPS, activeOff.ry, activeOff.rz))
        local yVec = deltaFromBase(measure(activeOff.rx, activeOff.ry + EPS, activeOff.rz))
        local zVec = deltaFromBase(measure(activeOff.rx, activeOff.ry, activeOff.rz + EPS))

        local xAxis = { x = xVec.x / EPS, y = xVec.y / EPS, z = xVec.z / EPS }
        local yAxis = { x = yVec.x / EPS, y = yVec.y / EPS, z = yVec.z / EPS }
        local zAxis = { x = zVec.x / EPS, y = zVec.y / EPS, z = zVec.z / EPS }
        local target = deltaFromBase(targetWorldRot)

        local drx, dry, drz = Solve3x3(xAxis, yAxis, zAxis, target)
        return activeOff.rx + drx, activeOff.ry + dry, activeOff.rz + drz
    end

    local function activeLabel()
        if parent and editingParent then return ('PARENT "%s"'):format(parent.model) end
        return parent and ('CHILD "%s"'):format(model) or ('"%s"'):format(model)
    end

    local function hintText()
        local tabHint = parent and '  [C] Switch Prop' or ''
        if gizmoActive then
            return ('Editing %s  |  GIZMO MODE  |  [Drag] Move  [G] Switch to Keyboard Mode  [ENTER] Confirm  [BACKSPACE] Cancel'):format(activeLabel())
        end
        return ('Editing %s%s  |  Step: %.2f / %.1f°  |  [G] Gizmo Mode  [Arrows] Move X/Y  [Scroll] Move Z  [Q/E] Yaw  [Shift+Arrows] Pitch/Roll  [ENTER] Confirm  [BACKSPACE] Cancel'):format(activeLabel(), tabHint, POS_STEP, ROT_STEP)
    end

    TextUIShow(hintText(), { position = 'left-center', icon = 'fas fa-hand-holding' })

    -- Leaves Gizmo Mode and calibrates the ACTIVE offset from wherever it was
    -- dragged to — position AND rotation, since the widget lets you rotate too
    -- (see calibrateRotation() above for why that needs its own pass). Safe to
    -- call whether triggered by [G] or by confirming while still in Gizmo Mode.
    local function exitGizmoMode()
        local activeOff, activeEntity, calibEntity, calibBoneIdx = Active()
        local targetWorldPos = GetEntityCoords(activeEntity)
        local tqx, tqy, tqz, tqw = GetEntityQuaternion(activeEntity)
        local targetWorldRot = { x = tqx, y = tqy, z = tqz, w = tqw }
        LeaveCursorMode()
        ExecuteCommand('-gizmoTranslation')
        TextUIShow('Calibrating position…', { position = 'left-center', icon = 'fas fa-hand-holding' })
        activeOff.x, activeOff.y, activeOff.z = calibrateOffset(targetWorldPos, calibEntity, calibBoneIdx, activeOff)
        TextUIShow('Calibrating rotation…', { position = 'left-center', icon = 'fas fa-hand-holding' })
        activeOff.rx, activeOff.ry, activeOff.rz = calibrateRotation(targetWorldRot, calibEntity, calibBoneIdx, activeOff)
        gizmoActive = false
    end

    local function cleanup()
        TextUIHide()
        if gizmoActive then
            LeaveCursorMode()
            ExecuteCommand('-gizmoTranslation')
        end
        if anim then ClearPedTasks(ped) end
        DetachEntity(prop, true, false)
        DeleteObject(prop)
        DeleteObject(refProp)
        if parentProp and DoesEntityExist(parentProp) then DeleteObject(parentProp) end
        SetModelAsNoLongerNeeded(hash)
        isPlacing = false
    end

    CreateThread(function()
        while isPlacing do
            for _, c in ipairs(CONTROLS) do DisableControlAction(0, c, true) end
            for _, c in ipairs(BLOCKED_CONTROLS) do DisableControlAction(0, c, true) end

            if switchRequested then
                switchRequested = false
                if parent and not gizmoActive then
                    editingParent = not editingParent
                    TextUIShow(hintText(), { position = 'left-center', icon = 'fas fa-hand-holding' })
                end
            end

            if IsDisabledControlJustPressed(0, 47) then -- G
                if gizmoActive then
                    exitGizmoMode()
                else
                    local _, activeEntity = Active()
                    gizmoActive = true
                    DetachEntity(activeEntity, true, false)
                    EnterCursorMode()
                    ExecuteCommand('+gizmoTranslation')
                end
                TextUIShow(hintText(), { position = 'left-center', icon = 'fas fa-hand-holding' })
            end

            if gizmoActive then
                DisablePlayerFiring(PlayerId(), true)

                local _, activeEntity = Active()
                local buffer = makeEntityMatrix(activeEntity)
                local changed = Citizen.InvokeNative(0xEB2EDCA2, buffer:Buffer(), 'Editor1', Citizen.ReturnResultAnyway())
                if changed then
                    applyEntityMatrix(activeEntity, buffer)
                end
            else
                -- Params match rpemotes' own addProp() exactly (Emote.lua:320-321) so the
                -- live preview here is a 1:1 match for how the emote will actually render it.
                if parent then
                    AttachLikeRpemotes(parentProp, ped, boneIdx, parentOff.x, parentOff.y, parentOff.z, parentOff.rx, parentOff.ry, parentOff.rz)
                end
                AttachLikeRpemotes(prop, parent and parentProp or ped, parent and 0 or boneIdx,
                    childOff.x, childOff.y, childOff.z, childOff.rx, childOff.ry, childOff.rz)

                local activeOff = Active()
                local shiftHeld = IsDisabledControlPressed(0, 21)

                if IsDisabledControlJustPressed(0, 172) then -- Arrow Up
                    if shiftHeld then activeOff.rx = activeOff.rx + ROT_STEP else activeOff.y = activeOff.y + POS_STEP end
                end
                if IsDisabledControlJustPressed(0, 173) then -- Arrow Down
                    if shiftHeld then activeOff.rx = activeOff.rx - ROT_STEP else activeOff.y = activeOff.y - POS_STEP end
                end
                if IsDisabledControlJustPressed(0, 174) then -- Arrow Left
                    if shiftHeld then activeOff.ry = activeOff.ry - ROT_STEP else activeOff.x = activeOff.x - POS_STEP end
                end
                if IsDisabledControlJustPressed(0, 175) then -- Arrow Right
                    if shiftHeld then activeOff.ry = activeOff.ry + ROT_STEP else activeOff.x = activeOff.x + POS_STEP end
                end
                if IsDisabledControlJustPressed(0, 241) then activeOff.z = activeOff.z + POS_STEP end -- Scroll up
                if IsDisabledControlJustPressed(0, 242) then activeOff.z = activeOff.z - POS_STEP end -- Scroll down
                if IsDisabledControlJustPressed(0, 44)  then activeOff.rz = activeOff.rz - ROT_STEP end -- Q
                if IsDisabledControlJustPressed(0, 38)  then activeOff.rz = activeOff.rz + ROT_STEP end -- E
            end

            local activeOff, activeEntity = Active()
            local coords = GetEntityCoords(activeEntity)
            if gizmoActive then
                -- activeOff is stale (last calibrated value) while actively dragging —
                -- showing it here would be misleading, so show a plain status instead.
                Draw3dLabel(coords.x, coords.y, coords.z + 0.15, 'Dragging… [G]/[ENTER] to calculate exact offset')
            else
                Draw3dLabel(coords.x, coords.y, coords.z + 0.15, ('Editing: %s\nPos: %.2f, %.2f, %.2f  Rot: %.1f, %.1f, %.1f'):format(
                    activeLabel(), activeOff.x, activeOff.y, activeOff.z, activeOff.rx, activeOff.ry, activeOff.rz))
            end

            if confirmRequested then
                confirmRequested = false
                if gizmoActive then exitGizmoMode() end
                cleanup()
                FinishAttach(model, boneId, childOff, parent, parentOff)
                return
            end

            if cancelRequested then
                cancelRequested = false
                cleanup()
                Notify('Prop attachment tool cancelled.', 'inform')
                return
            end

            Wait(0)
        end
    end)
end

-- ── Output ────────────────────────────────────────────────────────────────────

FinishAttach = function(model, boneId, childOff, parent, parentOff)
    if parent then
        local parentCode = ('%s = {\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n},'):format(
            'ParentOffset', parentOff.x, parentOff.y, parentOff.z, parentOff.rx, parentOff.ry, parentOff.rz)
        local childCode = ('%s = {\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n},'):format(
            'Offset', childOff.x, childOff.y, childOff.z, childOff.rx, childOff.ry, childOff.rz)

        print(('\n%s\n[Restaurant Tools] Prop Attachment Tool — "%s" (PARENT, on bone %d) + "%s" (CHILD, attached to parent) — NOT ped-bone PropPlacements:\n\n  Parent "%s" relative to bone %d:\n    %s\n\n  Child "%s" relative to parent "%s":\n    %s\n%s\n')
            :format(('='):rep(60), parent.model, boneId, model, parent.model, boneId, parentCode, model, parent.model, childCode, ('='):rep(60)))

        TriggerServerEvent(ResourceEvent('propattach:output'), model, boneId, parentCode .. '\n\n' .. childCode)

        lib.alertDialog({
            header   = 'Prop Attachment Tool — Done',
            content  = ('**Parent:** `%s` (bone `%d`)  \n**Parent Offset:** `{%.2f, %.2f, %.2f, %.2f, %.2f, %.2f}`  \n\n**Child:** `%s` (on parent)  \n**Child Offset:** `{%.2f, %.2f, %.2f, %.2f, %.2f, %.2f}`  \n\nAlso printed to **F8 console** and **server console**.'):format(
                parent.model, boneId, parentOff.x, parentOff.y, parentOff.z, parentOff.rx, parentOff.ry, parentOff.rz,
                model, childOff.x, childOff.y, childOff.z, childOff.rx, childOff.ry, childOff.rz),
            centered = true,
            cancel   = false,
        })
        return
    end

    local code = ('PropPlacement = {\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n    %.2f,\n},'):format(
        childOff.x, childOff.y, childOff.z, childOff.rx, childOff.ry, childOff.rz)

    print(('\n%s\n[Restaurant Tools] Prop Attachment Tool — "%s" on bone %d:\n    Prop = %q,\n    PropBone = %d,\n    %s\n%s\n')
        :format(('='):rep(60), model, boneId, model, boneId, code, ('='):rep(60)))

    TriggerServerEvent(ResourceEvent('propattach:output'), model, boneId, code)

    lib.alertDialog({
        header   = 'Prop Attachment Tool — Done',
        content  = ('**Model:** `%s`  \n**Bone:** `%d`  \n**PropPlacement:** `{%.2f, %.2f, %.2f, %.2f, %.2f, %.2f}`  \n\nAlso printed to **F8 console** and **server console**.'):format(
            model, boneId, childOff.x, childOff.y, childOff.z, childOff.rx, childOff.ry, childOff.rz),
        centered = true,
        cancel   = false,
    })
end

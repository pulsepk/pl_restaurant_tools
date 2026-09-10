-- Thin bridge to pl_lib exports, matching the shape pl_burgershot's own
-- client/lib.lua uses, so every tool file's Notify(...)/TextUIShow(...)/
-- TextUIHide() calls work unchanged.

local _lib = exports['pl_lib']

function Notify(message, ntype)
    _lib:Notify('Restaurant Tools', message, ntype)
end

function TextUIShow(text, opts)
    _lib:TextUIShow(text, opts)
end

function TextUIHide()
    _lib:TextUIHide()
end

function LoadAnimDict(dict)
    _lib:LoadAnimDict(dict)
end

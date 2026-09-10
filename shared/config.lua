Config = {}

Config.CommandPrefix = 'rt'    -- short prefix for tool commands (/rtchair, /rttable, /rtlocation, /rtprop, /rtattach)
Config.AcePermission = 'pl_restaurant.locationbuilder'  -- ace perm gating all tools in this resource
Config.EventPrefix   = GetCurrentResourceName()

function ResourceEvent(name)
    return Config.EventPrefix .. ':' .. name
end

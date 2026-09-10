fx_version 'cerulean'
games { 'gta5' }

author 'PulseScripts - pulsescripts.com'
description 'Restaurant content-authoring tools (chair/table/location builders, prop placer, prop attachment tuner)'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/lib.lua',
    'client/tools/dataview.lua',
    'client/tools/locationbuilder.lua',
    'client/tools/chairbuilder.lua',
    'client/tools/tablebuilder.lua',
    'client/tools/propplacer.lua',
    'client/tools/propattach.lua',
}

server_scripts {
    'server/main.lua',
}

dependencies {
    'ox_lib',
    'pl_lib',
}

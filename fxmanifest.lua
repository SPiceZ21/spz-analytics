fx_version 'cerulean'
game 'gta5'

name 'spz-analytics'
description 'SPiceZ analytics collector: player sessions, activity per mode, race funnel, laps, vehicle usage, feature usage, daily player stats and per-minute server snapshots, written in batches for Grafana.'
version '1.2.0'
author 'SPiceZ-Core'
lua54 'yes'

shared_script 'config.lua'

client_script 'client/main.lua'

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/db.lua',
  'server/main.lua',
  'server/race.lua',
  'server/server.lua',
}

dependencies {
  'oxmysql',
  'spz-core',
}

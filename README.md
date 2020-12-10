# TooManyPolys
This plugin replaces high-poly player models with low-poly versions to improve FPS.
				
A model is replaced only if other players in the same area can see it and if at least one of those players is seeing too many player model polygons. Models are replaced in order from most to least polygons, until the visible polygon count is below the limit for any given player.

Type `.hipoly` in console for commands/help.

## CVars
```
as_command hipoly.max_player_polys 64000
```
- `hipoly.max_player_polys` sets the maximum player model polygons that a player can view at once. Models are replaced until the number of visible polys is reduced below this limit.
  - I'm not sure yet what the optimum value for this is. 64k polies is probably too much. Remappable colors also affect performance significantly and that's not considered here yet.

## Installation
1. Create a symlink from `svencoop_addon/models/player` to `svencoop_addon/scripts/plugins/store/playermodelfolder`
1. Make sure the symlinked player model folder has _all_ available player models - **default models included!**. All player model paths must also be lowercase if served by a Linux host.
1. Add this to `default_plugins.txt`:
```
  "plugin"
  {
    "name" "TooManyPolys"
    "script" "TooManyPolys/TooManyPolys"
    "concommandns" "hipoly"
  }
```

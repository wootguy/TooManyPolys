# TooManyPolys
This plugin replaces high-poly player models with low-poly versions to improve FPS. Models are replaced in order from most to least polygons, until the visible 
polygon count is below a limit that you set. The plugin also prevents players from using old model names or unofficial model names introduced by players who copy-paste models and rename them.

Looking for models with a low poly count? Try here:  
https://wootguy.github.io/scmodels/

The model database needs to be updated as new models are released. Run `python update.py` occasionally or download `models.txt` and `aliases.txt` from this repo to keep up-to-date.

## CVars
- `as_command hipoly.default_poly_limit 32000` sets the default polygon limit.

## Commands
- `.hipoly` displays the help menu.
- `.hipoly [0/1/toggle]` toggles the polygon limit on/off.
- `.limitpoly X` changes the polygon limit (X = poly count, in thousands).
- `.listpoly` lists each player's desired model and polygon count.
- `.debugpoly [0/1/2]` set debug mode, which shows:
  - How many player model polys the server thinks you can see.
  - List of players who are having their models replaced
  - Lasers showing which models are replaced (mode 2 only)
    - No line = HD model (not replaced)
    - Yellow  = SD model
    - Red     = LD model

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

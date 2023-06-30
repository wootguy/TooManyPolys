cd "C:\Games\Steam\steamapps\common\Sven Co-op\svencoop\addons\metamod\dlls"

if exist PlayerStatus_old.dll (
    del TooManyPolys_old.dll
)
if exist TooManyPolys.dll (
    rename TooManyPolys.dll TooManyPolys_old.dll 
)

exit /b 0
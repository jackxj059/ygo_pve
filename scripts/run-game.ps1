# Starts the Godot test host (game/), or the Godot editor with -Editor.
# Run scripts/bootstrap.ps1 and scripts/build.ps1 first.
[CmdletBinding()]
param([switch]$Editor)
$root = Split-Path -Parent $PSScriptRoot
$godot = Join-Path $root 'tools/godot/Godot_v4.7.2-stable_win64.exe'
$godotArgs = @('--path', (Join-Path $root 'game'))
if ($Editor) { $godotArgs = @('--editor') + $godotArgs }
Start-Process -FilePath $godot -ArgumentList $godotArgs

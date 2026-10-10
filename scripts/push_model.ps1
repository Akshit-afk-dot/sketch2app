# Push the on-device layout model (.litertlm) into the app's external files folder over USB.
# The app reads it from there (Settings > Layout > On-device LLM); no root, no rebuild needed.
#
#   powershell -ExecutionPolicy Bypass -File scripts/push_model.ps1 -Model D:/sketch2app-data/llm/layout.litertlm
#
# Requires: USB debugging on, the app installed and opened once (so Android creates its folder).
param([Parameter(Mandatory = $true)][string]$Model)
$ErrorActionPreference = "Stop"

$adb = Join-Path $env:LOCALAPPDATA "Android/sdk/platform-tools/adb.exe"
if (-not (Test-Path $adb)) { $adb = "adb" }
if (-not (Test-Path $Model)) { throw "model not found: $Model" }

$dest = "/storage/emulated/0/Android/data/dev.sketch2app.sketch2app/files/models"
& $adb shell mkdir -p $dest
& $adb push $Model "$dest/layout.litertlm"
if ($LASTEXITCODE -ne 0) { throw "adb push failed" }
& $adb shell ls -l "$dest/layout.litertlm"
"Pushed. In the app: Settings > Layout > On-device LLM."

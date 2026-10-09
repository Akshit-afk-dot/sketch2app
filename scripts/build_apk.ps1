# Build the Android APK outside the repo, so Gradle caches and build output land on the data drive
# instead of C: (nearly full on the dev laptop) and outside OneDrive (which locks Gradle's cache files).
#
#   powershell -ExecutionPolicy Bypass -File scripts/build_apk.ps1 [-Mode release|debug]
#
# Output: $S2A_DATA_ROOT/apk/sketch2app-<mode>.apk (S2A_DATA_ROOT defaults to D:/sketch2app-data);
# full build log: $S2A_DATA_ROOT/build_apk.log.
param([ValidateSet("release", "debug")][string]$Mode = "release")
$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$work = if ($env:S2A_DATA_ROOT) { $env:S2A_DATA_ROOT } else { "D:/sketch2app-data" }
$dst = Join-Path $work "build/app"

robocopy (Join-Path $repo "app") $dst /MIR /XD build .dart_tool .gradle .idea /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

$env:GRADLE_USER_HOME = Join-Path $work "gradle"
$log = Join-Path $work "build_apk.log"
Push-Location $dst
try {
    # Through cmd: Windows PowerShell 5.1 turns any stderr line of a native tool into a terminating error,
    # which aborted Gradle on a harmless Kotlin-daemon warning.
    cmd /c "flutter build apk --$Mode --target-platform android-arm64 --suppress-analytics > `"$log`" 2>&1"
    $code = $LASTEXITCODE
    Get-Content $log -Tail 15
    if ($code -ne 0) { throw "flutter build failed with exit code $code (full log: $log)" }
} finally {
    Pop-Location
}

$apkDir = New-Item -ItemType Directory -Force (Join-Path $work "apk")
$out = Join-Path $apkDir "sketch2app-$Mode.apk"
Copy-Item (Join-Path $dst "build/app/outputs/flutter-apk/app-$Mode.apk") $out -Force
"APK: $out ({0:N1} MB)" -f ((Get-Item $out).Length / 1MB)

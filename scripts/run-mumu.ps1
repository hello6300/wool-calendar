# run-mumu.ps1 - Connect the Netease MuMu emulator and start a Flutter debug session.
# PowerShell 5.1+ / no Git Bash required. Kept ASCII-only on purpose (PS 5.1 reads
# BOM-less .ps1 as ANSI; non-ASCII text would be garbled).
#
#   powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1 -Check
#   powershell -ExecutionPolicy Bypass -File scripts\run-mumu.ps1
#
# Only the local Android SDK adb is used. Never use MuMu's bundled adb_server.exe:
# a different version starts its own server on 5037 and hides the device from Flutter.

param([switch]$Check)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

# User-level variables are persisted, but already-open shells do not refresh them.
$dev = 'D:\dev'
$env:JAVA_HOME = "$dev\jdk17"
$env:ANDROID_HOME = "$dev\android-sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PUB_CACHE = "C:\Users\$env:USERNAME\AppData\Local\Pub\Cache"
$env:LOCALAPPDATA = "C:\Users\$env:USERNAME\AppData\Local"
$env:APPDATA = "C:\Users\$env:USERNAME\AppData\Roaming"
$env:NO_PROXY = 'localhost,127.0.0.1,::1'
$env:PATH = "$dev\flutter\bin;$dev\flutter\bin\cache\dart-sdk\bin;$dev\jdk17\bin;$dev\android-sdk\platform-tools;$dev\bin;$env:PATH"

# Java/Gradle ignores HTTP_PROXY. Inject only when a proxy is actually set in this
# shell (normally there is none on a normal desktop terminal -> direct to mirrors).
$proxyUrl = if ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { '' }
if ($proxyUrl) {
    $hp = ($proxyUrl -replace '^[a-zA-Z]+://', '') -replace '/.*$', '' -replace '^.*@', ''
    $parts = $hp.Split(':')
    $proxyHost = $parts[0]
    $proxyPort = $parts[-1]
    if ($proxyHost -and $proxyPort -and $proxyHost -ne $proxyPort) {
        $env:JAVA_TOOL_OPTIONS = "-Dhttp.proxyHost=$proxyHost -Dhttp.proxyPort=$proxyPort -Dhttps.proxyHost=$proxyHost -Dhttps.proxyPort=$proxyPort -Dhttp.nonProxyHosts=localhost|127.0.0.1"
        Write-Host "Proxy: $proxyHost`:$proxyPort (injected into JAVA_TOOL_OPTIONS)"
    }
} else {
    Remove-Item Env:\JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
    Write-Host 'Proxy: none (direct to domestic mirrors)'
}

$adb = Join-Path $dev 'android-sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { throw "adb not found: $adb" }

# adb prints "daemon not running" to stderr; PS 5.1 wraps native stderr as an
# ErrorRecord, so swallow it instead of showing a scary red (but harmless) error.
$null = & $adb start-server 2>&1

# New MuMu listens on 5555 / 7555 / 16384 at once - aliases of the SAME device.
# Pick one explicitly, otherwise flutter run asks which device to use.
$device = ''
foreach ($port in 16384, 7555, 5555) {
    $null = & $adb connect "127.0.0.1:$port" 2>&1
    $state = (& $adb -s "127.0.0.1:$port" get-state 2>$null | Out-String).Trim()
    if ($state -eq 'device') { $device = "127.0.0.1:$port"; break }
}
if (-not $device) {
    & $adb devices -l
    throw 'MuMu not connected. Make sure the emulator has fully booted.'
}

$ver = (& $adb -s $device shell getprop ro.build.version.release 2>$null | Out-String).Trim()
$sdk = (& $adb -s $device shell getprop ro.build.version.sdk 2>$null | Out-String).Trim()
$abi = (& $adb -s $device shell getprop ro.product.cpu.abi 2>$null | Out-String).Trim()
Write-Host "Connected: $device | Android $ver (API $sdk) | $abi"

if ($Check) {
    Write-Host 'Check only. To install the prebuilt APK manually:'
    Write-Host "  adb -s $device install -r build\app\outputs\flutter-apk\app-debug.apk"
    Write-Host "  adb -s $device shell am start -n com.appforge.demo/.MainActivity"
    exit 0
}

Write-Host 'Starting flutter run (r = hot reload, R = hot restart, q = quit)'
& "$dev\flutter\bin\flutter.bat" run -d $device --device-timeout 60

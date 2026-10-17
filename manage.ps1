<#
  manage.ps1 - one script to install, test, check, stop and remove the OpenCode notifier.

  Run it like this (works even though Windows blocks scripts by default):
    powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\opencode-notify\manage.ps1" <command>

  Commands:
    install            copy the plugin into OpenCode's global plugin folder, create the desktop shortcut
    telegram           guided Telegram setup (bot token + chat id + test message)
    test <kind>        done | error | input | stalled | crashed      (add -Hold to ring until you stop it)
    status             show what is installed / running, plus the latest log lines
    stop-alarm         silence a ringing alarm right now
    pause / resume     turn all alerts off / on without uninstalling
    stop / start       stop / start the background watchdog (it also starts by itself with OpenCode)
    uninstall          remove the plugin, the shortcut and stop everything
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'test', 'status', 'stop-alarm', 'stop', 'start', 'pause', 'resume', 'telegram', 'help')]
    [string]$Command = 'help',
    [Parameter(Position = 1)]
    [string]$Arg = '',
    [string]$ProjectPath = '',
    [switch]$Hold
)

$ErrorActionPreference = 'Stop'
$Base      = $PSScriptRoot
$StateDir  = Join-Path $Base 'state'
$LogDir    = Join-Path $Base 'logs'
$ConfigPath = Join-Path $Base 'config.json'
New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $ConfigExample = Join-Path $Base 'config.example.json'
    if (-not (Test-Path -LiteralPath $ConfigExample)) { throw "Missing file: $ConfigExample" }
    Copy-Item -LiteralPath $ConfigExample -Destination $ConfigPath
}

$ConfigHome = $env:XDG_CONFIG_HOME
if (-not $ConfigHome) { $ConfigHome = Join-Path $env:USERPROFILE '.config' }
$GlobalPluginDir = Join-Path $ConfigHome 'opencode\plugins'
$PluginFile = 'notify-bridge.js'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Stop OpenCode Alarm.lnk'

function Start-Hidden([string]$Exe, [string]$ArgString) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
}

function Get-WatchdogProcs {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*watchdog.ps1*' })
}

function Start-Watchdog {
    if (@(Get-WatchdogProcs).Count -gt 0) { return $false }
    Start-Hidden 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $Base 'watchdog.ps1'))
    Start-Sleep -Seconds 2
    return $true
}

function Stop-Watchdog {
    foreach ($p in (Get-WatchdogProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Stop-AlarmNow {
    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Set-Content -Path (Join-Path $StateDir 'stop-alarm.flag') -Value $ms
}

function Read-ConfigObject { Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }

function Save-ConfigObject($Obj) {
    $json = $Obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ install
function Invoke-Install {
    foreach ($f in 'notify-bridge.js', 'alert.ps1', 'watchdog.ps1', 'config.json') {
        if (-not (Test-Path (Join-Path $Base $f))) { throw "Missing file: $f  (all files must be in $Base)" }
    }
    Get-ChildItem -Path $Base -File | Unblock-File -ErrorAction SilentlyContinue

    $dest = $GlobalPluginDir
    if ($ProjectPath) { $dest = Join-Path $ProjectPath '.opencode\plugins' }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $Base $PluginFile) -Destination (Join-Path $dest $PluginFile) -Force
    Write-Host "Plugin installed: $(Join-Path $dest $PluginFile)"

    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($ShortcutPath)
        $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" stop-alarm' -f $PSCommandPath
        $sc.WorkingDirectory = $Base
        $sc.Save()
        Write-Host "Desktop shortcut created: $ShortcutPath  (double-click it to silence the alarm)"
    } catch {
        Write-Host "Could not create the desktop shortcut: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host '  1. (optional) set up Telegram:   manage.ps1 telegram'
    Write-Host '  2. test the alarm:               manage.ps1 test done'
    Write-Host '  3. fully close OpenCode and start it again, then run:   manage.ps1 status'
    Write-Host '     The log must contain a "plugin loaded" line.'
}

# ------------------------------------------------------------------ uninstall
function Invoke-Uninstall {
    Stop-AlarmNow
    Start-Sleep -Milliseconds 800
    Stop-Watchdog
    foreach ($d in @($GlobalPluginDir, $(if ($ProjectPath) { Join-Path $ProjectPath '.opencode\plugins' }))) {
        if ($d) {
            $f = Join-Path $d $PluginFile
            if (Test-Path $f) { Remove-Item -Path $f -Force; Write-Host "Removed $f" }
        }
    }
    if (Test-Path $ShortcutPath) { Remove-Item -Path $ShortcutPath -Force; Write-Host "Removed $ShortcutPath" }
    Get-ChildItem -Path $StateDir -Filter 'instance-*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host 'The notifier is disconnected from OpenCode. To delete its folder as well (this also deletes your Telegram token):'
    Write-Host "  Remove-Item -Recurse -Force `"$Base`""
    Write-Host 'If you used a Telegram bot: open @BotFather, send /deletebot (or /revoke) to invalidate the token.'
}

# ------------------------------------------------------------------ telegram setup
function Invoke-TelegramSetup {
    Write-Host '1. In Telegram open @BotFather, send /newbot, choose a name and a username ending in "bot".'
    Write-Host '2. BotFather replies with a token that looks like 123456789:AAxxxxxxxxxxxxxxxx'
    $token = (Read-Host 'Paste the bot token here').Trim()
    if (-not $token) { throw 'No token entered.' }
    Write-Host ''
    Write-Host '3. Open your new bot in Telegram, press START and send it any message (for example: hi).'
    [void](Read-Host 'Press Enter here AFTER you sent that message')

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cfg = Read-ConfigObject
    $proxyArgs = @{}
    if ($cfg.telegram.proxy) { $proxyArgs.Proxy = [string]$cfg.telegram.proxy }
    $api = "https://api.telegram.org/bot$token"

    $r = Invoke-RestMethod -Uri "$api/getUpdates" -TimeoutSec 20 @proxyArgs
    $chat = $null
    foreach ($u in @($r.result)) { if ($u.message -and $u.message.chat.id) { $chat = $u.message.chat.id } }
    if (-not $chat) { throw 'No message from you was found. Make sure you pressed START and sent a message to YOUR bot, then run this command again.' }

    $cfg.telegram.botToken = $token
    $cfg.telegram.chatId   = [string]$chat
    $cfg.telegram.enabled  = $true
    Save-ConfigObject $cfg
    Write-Host "Saved. Your chat id is $chat."

    Invoke-RestMethod -Uri "$api/sendMessage" -Method Post -TimeoutSec 20 @proxyArgs `
        -Body @{ chat_id = [string]$chat; text = 'OpenCode notifier connected. You will get alerts here.' } | Out-Null
    Write-Host 'A test message was sent to your phone. Next: manage.ps1 test done'
}

# ------------------------------------------------------------------ tests
function Invoke-Test([string]$Kind) {
    $extra = @()
    if (-not $Hold) { $extra = @('-MaxSeconds', '10') }
    $alert = Join-Path $Base 'alert.ps1'
    $cfg = Read-ConfigObject

    if (@('done', 'error', 'input') -contains $Kind) {
        $msgs = @{
            done  = '[test] Task finished after 3m 20s. Waiting for your next prompt.'
            error = '[test] APIError: simulated error'
            input = '[test] Waiting for your approval: bash: npm install'
        }
        Write-Host "Playing the '$Kind' alarm. Telegram message is sent too if configured."
        if ($Hold) { Write-Host 'It rings until you run "stop-alarm", double-click the desktop shortcut, or reply on Telegram.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $alert -Kind $Kind -Message $msgs[$Kind] -Force @extra
    }
    elseif ($Kind -eq 'crashed') {
        [void](Start-Watchdog)
        $fake = Join-Path $StateDir 'instance-2147483000.json'
        $obj = [ordered]@{
            pid = 2147483000; startedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); project = 'test-crash'
            status = 'busy'; lastEvent = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); activeTool = $null; test = $true
        }
        $obj | ConvertTo-Json | Set-Content -Path $fake -Encoding UTF8
        Write-Host 'Injected a fake "OpenCode process vanished while busy". The watchdog should alarm within ~10 seconds...'
        Start-Sleep -Seconds 14
        Remove-Item -Path $fake -Force -ErrorAction SilentlyContinue
    }
    elseif ($Kind -eq 'stalled') {
        [void](Start-Watchdog)
        $limit = 300
        if ($cfg.stall.noActivitySeconds) { $limit = [int]$cfg.stall.noActivitySeconds }
        $sleeper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 800
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $fake = Join-Path $StateDir ("instance-{0}.json" -f $sleeper.Id)
        $obj = [ordered]@{
            pid = $sleeper.Id; startedMs = $nowMs; project = 'test-stall'
            status = 'busy'; lastEvent = ($nowMs - (($limit + 60) * 1000)); activeTool = $null; test = $true
        }
        $obj | ConvertTo-Json | Set-Content -Path $fake -Encoding UTF8
        Write-Host 'Injected a fake "busy but silent for a long time" OpenCode. The watchdog should alarm within ~10 seconds...'
        Start-Sleep -Seconds 14
        Remove-Item -Path $fake -Force -ErrorAction SilentlyContinue
        Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
    }
    else {
        throw "Unknown test '$Kind'. Use one of: done, error, input, stalled, crashed"
    }
}

# ------------------------------------------------------------------ status
function Show-Status {
    $cfg = Read-ConfigObject
    Write-Host "Folder            : $Base"
    $installed = Join-Path $GlobalPluginDir $PluginFile
    Write-Host ("Plugin (global)   : {0}" -f $(if (Test-Path $installed) { "installed ($installed)" } else { 'NOT installed - run: manage.ps1 install' }))
    Write-Host ("Paused            : {0}" -f (Test-Path (Join-Path $StateDir 'paused.flag')))
    Write-Host ("Telegram          : {0}" -f $(if ($cfg.telegram.enabled -and $cfg.telegram.botToken) { 'configured' } else { 'not configured' }))
    Write-Host ("Watchdog running  : {0}" -f (@(Get-WatchdogProcs).Count -gt 0))
    $pidFile = Join-Path $StateDir 'alarm.pid'
    $ringing = $false
    if (Test-Path $pidFile) {
        $ap = Get-Process -Id ([int](Get-Content $pidFile -Raw).Trim()) -ErrorAction SilentlyContinue
        $ringing = [bool]$ap
    }
    Write-Host ("Alarm ringing     : {0}" -f $ringing)
    Write-Host ''
    Write-Host 'OpenCode instances known to the plugin:'
    $files = @(Get-ChildItem -Path $StateDir -Filter 'instance-*.json' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Host '  (none - start OpenCode; if it still shows none, the plugin did not load)' }
    foreach ($f in $files) {
        try {
            $s = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $age = [Math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$s.lastEvent) / 1000)
            $alive = [bool](Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue)
            Write-Host ("  pid {0}  project '{1}'  status {2}  last activity {3}s ago  process alive: {4}" -f $s.pid, $s.project, $s.status, $age, $alive)
        } catch { }
    }
    Write-Host ''
    foreach ($name in 'events.log', 'alerts.log', 'watchdog.log') {
        $p = Join-Path $LogDir $name
        if (Test-Path $p) {
            Write-Host "--- last lines of logs\$name"
            Get-Content -Path $p -Tail 8 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
        }
    }
}

function Show-Help {
    Write-Host @'
OpenCode notifier - manage.ps1 commands

  install          copy the plugin into OpenCode's plugin folder + create the desktop "stop alarm" shortcut
  telegram         guided Telegram setup (bot token, chat id, test message)
  test <kind>      done | error | input | stalled | crashed   (add -Hold to ring until you stop it)
  status           what is installed / running, plus the latest log lines
  stop-alarm       silence a ringing alarm right now
  pause / resume   turn all alerts off / on without uninstalling
  stop / start     stop / start the background watchdog (it also starts by itself with OpenCode)
  uninstall        remove the plugin and the shortcut, stop everything

Run it as:
  powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\opencode-notify\manage.ps1" <command>
'@
}

switch ($Command) {
    'install'    { Invoke-Install }
    'uninstall'  { Invoke-Uninstall }
    'telegram'   { Invoke-TelegramSetup }
    'test'       { Invoke-Test $Arg }
    'status'     { Show-Status }
    'stop-alarm' { Stop-AlarmNow; Write-Host 'Stop signal sent.' }
    'pause'      { Set-Content -Path (Join-Path $StateDir 'paused.flag') -Value 'paused'; Stop-AlarmNow; Write-Host 'Alerts paused. Undo with: resume' }
    'resume'     { Remove-Item -Path (Join-Path $StateDir 'paused.flag') -Force -ErrorAction SilentlyContinue; Write-Host 'Alerts resumed.' }
    'stop'       { Stop-Watchdog; Write-Host 'Watchdog stopped (it starts again next time OpenCode starts; use "pause" to silence everything).' }
    'start'      { if (Start-Watchdog) { Write-Host 'Watchdog started.' } else { Write-Host 'Watchdog was already running.' } }
    default      { Show-Help }
}

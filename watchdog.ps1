<#
  watchdog.ps1 - watches OpenCode from OUTSIDE, because a crashed or frozen OpenCode cannot
  report its own problem.

  The plugin (notify-bridge.js) writes state\instance-<pid>.json for every running OpenCode:
  its process id, whether it is idle / busy / waiting, and when it last showed any activity.

  This script checks those files every few seconds and raises two kinds of alarm:
    crashed  the OpenCode process is gone although it was busy or waiting for you
             (or it exited with an error code)
    stalled  OpenCode says it is busy but has shown NO activity for a long time
             (default 5 minutes; 30 minutes while a tool such as a build or test run is active)

  It starts automatically when OpenCode starts, allows only one copy of itself, and quits by
  itself two minutes after the last OpenCode window has closed.
#>
$ErrorActionPreference = 'Continue'
$Base     = $PSScriptRoot
$StateDir = Join-Path $Base 'state'
$LogDir   = Join-Path $Base 'logs'
New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null
$LogFile  = Join-Path $LogDir 'watchdog.log'

function Write-Log([string]$Text) {
    try { Add-Content -Path $LogFile -Encoding UTF8 -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) } catch { }
}

# Only one watchdog at a time (the OpenCode plugin tries to start one every time OpenCode starts).
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\OpenCodeNotifyWatchdog', [ref]$created)
if (-not $created) { exit 0 }
Write-Log 'watchdog started'

function Read-Config {
    try { return (Get-Content -Path (Join-Path $Base 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Start-Hidden([string]$Exe, [string]$ArgString) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [void][System.Diagnostics.Process]::Start($psi)
}

function Start-Alert([string]$Kind, [string]$Msg, [bool]$IsTest) {
    $Msg = ($Msg -replace '["\\\r\n]', ' ')
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $argString = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Kind {1} -SpawnedAt {2} -Message "{3}"' -f (Join-Path $Base 'alert.ps1'), $Kind, $now, $Msg
    if ($IsTest) { $argString += ' -Force -MaxSeconds 10' }
    Write-Log ("ALERT {0}: {1}" -f $Kind, $Msg)
    Start-Hidden 'powershell.exe' $argString
}

function Test-InstanceAlive($s) {
    $p = Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    # Guard against Windows re-using the process id: a process that started AFTER the plugin
    # recorded its state cannot be the same OpenCode.
    try {
        $recorded = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$s.startedMs).UtcDateTime
        if ($p.StartTime.ToUniversalTime() -gt $recorded.AddSeconds(15)) { return $false }
    } catch { }
    return $true
}

$alerted  = @{}
$emptySince = $null
$idleExitSeconds = 120

try {
    while ($true) {
        $Config = Read-Config
        $poll = 5
        $stallIdle = 300
        $stallTool = 1800
        if ($Config) {
            if ($Config.pollSeconds) { $poll = [Math]::Max(2, [int]$Config.pollSeconds) }
            if ($Config.stall -and $Config.stall.noActivitySeconds)  { $stallIdle = [int]$Config.stall.noActivitySeconds }
            if ($Config.stall -and $Config.stall.toolRunningSeconds) { $stallTool = [int]$Config.stall.toolRunningSeconds }
        }
        Start-Sleep -Seconds $poll

        if (Test-Path (Join-Path $StateDir 'paused.flag')) { continue }

        $files = @(Get-ChildItem -Path $StateDir -Filter 'instance-*.json' -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            if (-not $emptySince) { $emptySince = Get-Date }
            elseif (((Get-Date) - $emptySince).TotalSeconds -gt $idleExitSeconds) { break }
            continue
        }
        $emptySince = $null

        foreach ($f in $files) {
            try {
                $s = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $isTest = [bool]($s.test -eq $true)
                $project = [string]$s.project

                if (-not (Test-InstanceAlive $s)) {
                    if ($s.status -eq 'crashed') {
                        Start-Alert 'crashed' ("[{0}] OpenCode exited with an error (exit code {1}) while it was working." -f $project, $s.exitCode) $isTest
                    } elseif ($s.status -eq 'busy' -or $s.status -eq 'waiting') {
                        Start-Alert 'crashed' ("[{0}] OpenCode stopped unexpectedly: the process is gone although it was {1}." -f $project, $s.status) $isTest
                    } else {
                        Write-Log ("instance {0} ({1}) ended normally" -f $s.pid, $project)
                    }
                    Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
                    continue
                }

                if ($s.status -eq 'busy') {
                    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $quiet = ($nowMs - [long]$s.lastEvent) / 1000
                    $limit = $stallIdle
                    $toolNote = ''
                    if ($s.activeTool) { $limit = $stallTool; $toolNote = (' (a "{0}" tool call is still running)' -f $s.activeTool) }
                    $key = '{0}|{1}' -f $s.pid, $s.lastEvent
                    if (($quiet -gt $limit) -and (-not $alerted.ContainsKey($key))) {
                        $alerted[$key] = $true
                        $mins = [Math]::Round($quiet / 60, 1)
                        Start-Alert 'stalled' ("[{0}] No activity from OpenCode for {1} min while it is working{2}. It may be stuck, or just very slow." -f $project, $mins, $toolNote) $isTest
                    }
                }
            } catch {
                # file was being written at that moment - try again next round
            }
        }
        if ($alerted.Count -gt 200) { $alerted.Clear() }
    }
} finally {
    Write-Log 'watchdog stopped'
    try { $mutex.ReleaseMutex() } catch { }
}

<#
  alert.ps1 - plays the alarm and sends the Telegram message.

  Started automatically by the OpenCode plugin (notify-bridge.js) and by watchdog.ps1.
  You can also run it by hand to test your sound / Telegram settings:

    powershell -NoProfile -ExecutionPolicy Bypass -File alert.ps1 -Kind error -Message "[test] hello" -Force -MaxSeconds 10

  Kinds: done | error | input | stalled | crashed      (settings live in config.json)
  -Force       ignore the "you are at the computer" check and always do the full alarm
  -MaxSeconds  stop after this many seconds (default: alarmMaxSeconds from config.json)
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('done', 'error', 'input', 'stalled', 'crashed')]
    [string]$Kind,
    [string]$Message = '',
    [long]$SpawnedAt = 0,
    [int]$MaxSeconds = 0,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Base     = $PSScriptRoot
$StateDir = Join-Path $Base 'state'
$LogDir   = Join-Path $Base 'logs'
New-Item -ItemType Directory -Force -Path $StateDir, $LogDir | Out-Null
$LogFile  = Join-Path $LogDir 'alerts.log'

function Write-Log([string]$Text) {
    try {
        Add-Content -Path $LogFile -Encoding UTF8 -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Kind, $Text)
    } catch { }
}

# ---------------------------------------------------------------- pause switch
if (Test-Path (Join-Path $StateDir 'paused.flag')) { Write-Log 'paused - skipped'; exit 0 }

# ---------------------------------------------------------------- config
try {
    $Config = Get-Content -Path (Join-Path $Base 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Log ('cannot read config.json: ' + $_.Exception.Message); exit 1
}
$K = $Config.kinds.$Kind
if (-not $K) { Write-Log 'no settings for this kind in config.json'; exit 1 }
if ($K.enabled -eq $false) { Write-Log 'this kind is disabled in config.json'; exit 0 }

# ---------------------------------------------------------------- helper C# code
$IdleSource = @'
using System;
using System.Runtime.InteropServices;
public static class OcIdle {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint IdleSeconds() {
        LASTINPUTINFO i = new LASTINPUTINFO();
        i.cbSize = (uint)Marshal.SizeOf(i);
        if (!GetLastInputInfo(ref i)) return 0;
        uint now = unchecked((uint)Environment.TickCount);
        return unchecked(now - i.dwTime) / 1000;
    }
}
'@

$AudioSource = @'
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int _0(); int _1(); int _2(); int _3();
    int SetMasterVolumeLevelScalar(float fLevel, System.Guid pguidEventContext);
    int _5();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int _7(); int _8(); int _9(); int _10();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, System.Guid pguidEventContext);
    int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref System.Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int _0();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("BCDE0395-E52F-4F03-9E37-AD56C0D1D8B4")]
class MMDeviceEnumeratorComObject { }
public class OcAudio {
    static IAudioEndpointVolume Vol() {
        var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
        IMMDevice dev = null;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
        IAudioEndpointVolume epv = null;
        var epvid = typeof(IAudioEndpointVolume).GUID;
        Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
        return epv;
    }
    public static float GetVolume() { float v = -1; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
    public static void SetVolume(float v) { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(v, System.Guid.Empty)); }
    public static bool GetMute() { bool m; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
    public static void SetMute(bool m) { Marshal.ThrowExceptionForHR(Vol().SetMute(m, System.Guid.Empty)); }
}
'@

# ---------------------------------------------------------------- sound
# Fallback beep patterns (frequency Hz, length ms) used when the .wav file is missing.
$Patterns = @{
    done    = @(@(880, 150), @(1175, 150), @(1568, 300))
    error   = @(@(400, 250), @(800, 250), @(400, 250), @(800, 250))
    input   = @(@(988, 200), @(988, 200), @(1319, 400))
    stalled = @(@(700, 300), @(500, 300), @(700, 300), @(500, 300))
    crashed = @(@(300, 400), @(300, 400), @(300, 400))
}
$script:player = $null

function Start-Sound([bool]$Sync) {
    $file = [string]$K.sound
    if ($file) { $file = [Environment]::ExpandEnvironmentVariables($file) }
    if ($file -and (Test-Path -LiteralPath $file)) {
        try {
            if (-not $script:player) {
                $script:player = New-Object System.Media.SoundPlayer $file
                $script:player.Load()
            }
            if ($Sync) { $script:player.PlaySync() } else { $script:player.Play() }
            return
        } catch {
            Write-Log ('could not play the .wav (only .wav files work): ' + $_.Exception.Message)
        }
    }
    foreach ($b in $Patterns[$Kind]) {
        try { [Console]::Beep([int]$b[0], [int]$b[1]) } catch { Start-Sleep -Milliseconds ([int]$b[1]) }
    }
}

# ---------------------------------------------------------------- volume (optional)
$volFile = Join-Path $StateDir 'volume-original.txt'
$script:volRaised = $false
$inv = [Globalization.CultureInfo]::InvariantCulture

function Set-LoudVolume {
    $pct = 0
    if ($Config.forceVolumePercent) { $pct = [int]$Config.forceVolumePercent }
    if ($pct -le 0) { return }
    try {
        Add-Type -TypeDefinition $AudioSource
        if (-not (Test-Path $volFile)) {
            $orig = '{0};{1}' -f ([OcAudio]::GetVolume().ToString($inv)), [OcAudio]::GetMute()
            Set-Content -Path $volFile -Value $orig
        }
        [OcAudio]::SetMute($false)
        [OcAudio]::SetVolume([single]([Math]::Min($pct, 100) / 100.0))
        $script:volRaised = $true
    } catch {
        Write-Log ('could not raise the volume: ' + $_.Exception.Message)
    }
}

function Restore-Volume {
    if (-not $script:volRaised) { return }
    try {
        if (Test-Path $volFile) {
            $parts = (Get-Content -Path $volFile -Raw).Trim().Split(';')
            [OcAudio]::SetVolume([single]::Parse($parts[0], $inv))
            [OcAudio]::SetMute([bool]::Parse($parts[1]))
            Remove-Item -Path $volFile -Force
        }
    } catch {
        Write-Log ('could not restore the volume: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- Telegram
function Test-TgConfigured {
    $t = $Config.telegram
    return [bool]($t -and $t.enabled -and $t.botToken -and $t.chatId)
}

function Invoke-Tg([string]$Method, [hashtable]$Payload) {
    $t = $Config.telegram
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $params = @{
        Uri         = ('https://api.telegram.org/bot{0}/{1}' -f $t.botToken, $Method)
        Method      = 'Post'
        TimeoutSec  = 15
        ContentType = 'application/json; charset=utf-8'
        Body        = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress))
    }
    if ($t.proxy) { $params.Proxy = [string]$t.proxy }
    return Invoke-RestMethod @params
}

function Send-Tg([string]$Text) {
    try {
        Invoke-Tg 'sendMessage' @{ chat_id = [string]$Config.telegram.chatId; text = $Text } | Out-Null
        return $true
    } catch {
        $msg = $_.Exception.Message.Replace([string]$Config.telegram.botToken, '***')
        Write-Log ('Telegram send failed: ' + $msg)
        return $false
    }
}

$script:tgBase = 0
function Initialize-TgAck {
    try {
        $r = Invoke-Tg 'getUpdates' @{ offset = -1; limit = 1; timeout = 0 }
        $items = @($r.result)
        if ($r.ok -and $items.Count -gt 0) { $script:tgBase = [long]$items[-1].update_id }
    } catch { }
}

function Test-TgAck {
    # True when YOU (the configured chat) sent any message to the bot after the alarm started.
    try {
        $r = Invoke-Tg 'getUpdates' @{ offset = ($script:tgBase + 1); timeout = 0 }
        $hit = $false
        foreach ($u in @($r.result)) {
            $script:tgBase = [Math]::Max($script:tgBase, [long]$u.update_id)
            if ($u.message -and ([string]$u.message.chat.id -eq [string]$Config.telegram.chatId)) { $hit = $true }
        }
        return $hit
    } catch { return $false }
}

# ---------------------------------------------------------------- are you at the computer?
$away = $true
$awayAfter = 0
if ($Config.awayAfterIdleSeconds) { $awayAfter = [int]$Config.awayAfterIdleSeconds }
if ((-not $Force) -and ($awayAfter -gt 0)) {
    try {
        Add-Type -TypeDefinition $IdleSource
        $idle = [OcIdle]::IdleSeconds()
        $away = ($idle -ge $awayAfter)
        Write-Log ('keyboard/mouse idle for {0}s (away after {1}s) -> away={2}' -f $idle, $awayAfter, $away)
    } catch {
        Write-Log ('idle check failed, assuming you are away: ' + $_.Exception.Message)
    }
}
if (-not $away) {
    Write-Log 'you are at the computer: one short sound only'
    Start-Sound $true
    exit 0
}

# ---------------------------------------------------------------- only one alarm at a time
$pidFile = Join-Path $StateDir 'alarm.pid'
try {
    if (Test-Path $pidFile) {
        $old = [int](Get-Content -Path $pidFile -Raw).Trim()
        if ($old -ne $PID) {
            $proc = Get-Process -Id $old -ErrorAction SilentlyContinue
            if ($proc -and ($proc.ProcessName -match 'powershell|pwsh')) { Stop-Process -Id $old -Force }
        }
    }
} catch { }
Set-Content -Path $pidFile -Value $PID

# ---------------------------------------------------------------- alarm settings
$maxSec = 600
if ($Config.alarmMaxSeconds) { $maxSec = [int]$Config.alarmMaxSeconds }
if ($MaxSeconds -gt 0) { $maxSec = $MaxSeconds }
$repeat = ($K.repeat -eq $true)
$every = 10
if ($K.repeatEverySeconds) { $every = [Math]::Max(2, [int]$K.repeatEverySeconds) }

$spawnedUtc = [DateTime]::UtcNow
if ($SpawnedAt -gt 0) { $spawnedUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($SpawnedAt).UtcDateTime }
$stopFlag   = Join-Path $StateDir 'stop-alarm.flag'
$alarmStart = Get-Date

function Get-StopReason {
    try {
        if ((Test-Path $stopFlag) -and ((Get-Item $stopFlag).LastWriteTimeUtc -gt $spawnedUtc)) {
            return 'stopped on the PC, or OpenCode resumed'
        }
    } catch { }
    if (((Get-Date) - $alarmStart).TotalSeconds -ge $maxSec) { return 'time limit reached' }
    return $null
}

# ---------------------------------------------------------------- Telegram message
$tgOn = (($K.telegram -ne $false) -and (Test-TgConfigured))
$script:lastTgSend = Get-Date
$script:lastPoll   = Get-Date
$script:reminders  = 0
$emoji = [string]$K.emoji
$title = [string]$K.title
$body  = $Message
if (-not $body) { $body = $title }

$early = Get-StopReason
if ($early -and ($early -ne 'time limit reached')) {
    Write-Log "not alarming: $early before the alarm even started"
    exit 0
}

if ($tgOn) {
    Initialize-TgAck
    if (Send-Tg ("$emoji $title`n$body")) { Write-Log 'Telegram message sent' }
}
Write-Log ('ALARM start: ' + $body)

function Get-RepeatStopReason {
    $r = Get-StopReason
    if ($r) { return $r }
    if ($tgOn) {
        if (((Get-Date) - $script:lastPoll).TotalSeconds -ge 6) {
            $script:lastPoll = Get-Date
            if (Test-TgAck) {
                [void](Send-Tg 'Alarm stopped.')
                return 'you replied on Telegram'
            }
        }
        $remMin = 3
        $remMax = 3
        if ($Config.telegram.reminderEveryMinutes) { $remMin = [double]$Config.telegram.reminderEveryMinutes }
        if ($Config.telegram.maxReminders) { $remMax = [int]$Config.telegram.maxReminders }
        if (($script:reminders -lt $remMax) -and (((Get-Date) - $script:lastTgSend).TotalMinutes -ge $remMin)) {
            $script:reminders++
            $script:lastTgSend = Get-Date
            [void](Send-Tg ("$emoji Still waiting (reminder {0}): {1}`nReply with any message to stop the alarm." -f $script:reminders, $body))
        }
    }
    return $null
}

# ---------------------------------------------------------------- play
$stopReason = $null
try {
    Set-LoudVolume
    if (-not $repeat) {
        Start-Sound $true
    } else {
        while ($true) {
            Start-Sound $false
            $until = (Get-Date).AddSeconds($every)
            while ((Get-Date) -lt $until) {
                $stopReason = Get-RepeatStopReason
                if ($stopReason) { break }
                Start-Sleep -Milliseconds 250
            }
            if ($stopReason) { break }
        }
        if ($script:player) { $script:player.Stop() }
    }
} finally {
    Restore-Volume
    try {
        if ((Test-Path $pidFile) -and ((Get-Content -Path $pidFile -Raw).Trim() -eq [string]$PID)) { Remove-Item -Path $pidFile -Force }
    } catch { }
    if ($stopReason) { Write-Log "ALARM end: $stopReason" } else { Write-Log 'ALARM end' }
}

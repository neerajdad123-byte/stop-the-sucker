#Requires -Version 5.1
<#
  start-updates.ps1

  Puts Windows Update back the way it was: services re-enabled, policies
  removed, pause cleared, update tasks re-enabled, power menu normal again.

  Needs Administrator. Double-click start-updates.bat if you'd rather not open
  PowerShell yourself.

  It reads the originals that stop-the-sucker.ps1 saved. If that file is
  missing it falls back to the Windows defaults.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$StateDir  = Join-Path $env:ProgramData 'stop-the-sucker'
$StateFile = Join-Path $StateDir 'originals.json'
$TaskBkDir = Join-Path $StateDir 'task_backup'
$LogFile   = Join-Path $StateDir ('start-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {}

function Say  { param($m) Write-Host $m }
function Good { param($m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Bad  { param($m) Write-Host "  [fail] $m" -ForegroundColor Red }
function Step { param($m) Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }

function End-Script {
    param([int]$Code)
    try { Stop-Transcript | Out-Null } catch {}
    exit $Code
}

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Bad 'This needs Administrator rights.'
    Say '  Right-click start-updates.bat and choose "Run as administrator".'
    End-Script 1
}

Say '--------------------------------------------------------------'
Say ' start updates - putting Windows Update back'
Say (' machine : ' + $env:COMPUTERNAME)
Say '--------------------------------------------------------------'

# Windows defaults, used when no saved state exists.
$defaults = @{ 'wuauserv' = 3; 'UsoSvc' = 2; 'WaaSMedicSvc' = 3 }

$Services = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')

$PolicyKeys = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
)

$TaskFolders = @(
    '\Microsoft\Windows\UpdateOrchestrator\',
    '\Microsoft\Windows\WindowsUpdate\',
    '\Microsoft\Windows\WaaSMedic\',
    '\Microsoft\Windows\InstallService\'
)

$TaskFileDirs = @(
    (Join-Path $env:WINDIR 'System32\Tasks\Microsoft\Windows\UpdateOrchestrator'),
    (Join-Path $env:WINDIR 'System32\Tasks\Microsoft\Windows\WindowsUpdate'),
    (Join-Path $env:WINDIR 'System32\Tasks\Microsoft\Windows\WaaSMedic')
)

$OrchKey   = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator'
$UxKey     = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$PauseVals = @(
    'PauseFeatureUpdatesStartTime',
    'PauseFeatureUpdatesEndTime',
    'PauseQualityUpdatesStartTime',
    'PauseQualityUpdatesEndTime',
    'PauseUpdatesExpiryTime'
)

# ------------------------------------------------------------- saved originals
$saved = $null
if (Test-Path $StateFile) {
    try {
        $saved = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
        Good ("originals loaded from " + $StateFile)
        if ($saved.CapturedAt) { Say ("        captured " + $saved.CapturedAt + " on " + $saved.Machine) }
    } catch {
        Warn ('could not read ' + $StateFile + ' - using Windows defaults')
    }
} else {
    Warn 'no saved originals found - using Windows defaults'
}

# ---------------------------------------------------------------- 1. services
Step '1/6  Re-enable the update services'

foreach ($s in $Services) {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (-not (Test-Path $k)) { Warn "$s does not exist, skipping"; continue }

    $target = $defaults[$s]
    if ($saved -and $saved.ServiceStart -and $null -ne $saved.ServiceStart.$s) {
        $target = [int]$saved.ServiceStart.$s
    }

    try {
        Set-ItemProperty -Path $k -Name Start -Value $target -Type DWord -Force -ErrorAction Stop
        Good ("$s Start=$target")
    } catch {
        Bad ("$s Start write failed: " + $_.Exception.Message)
    }
}

foreach ($s in @('wuauserv', 'UsoSvc')) {
    try { Start-Service -Name $s -ErrorAction Stop; Good "$s started" }
    catch { Warn ("$s did not start: " + $_.Exception.Message) }
}

# ------------------------------------------------------------ 2. remove policy
Step '2/6  Remove the update policies'

foreach ($p in $PolicyKeys) {
    if (Test-Path $p) {
        try { Remove-Item -Path $p -Recurse -Force -ErrorAction Stop; Good ("removed " + $p) }
        catch { Warn ("could not remove " + $p + ": " + $_.Exception.Message) }
    } else {
        Say ("  not present: " + $p)
    }
}

# ------------------------------------------------------------- 3. clear pause
Step '3/6  Clear the 2099 pause'

foreach ($v in $PauseVals) {
    $existing = (Get-ItemProperty $UxKey -Name $v -ErrorAction SilentlyContinue).$v
    if ($null -ne $existing) {
        try { Remove-ItemProperty -Path $UxKey -Name $v -Force -ErrorAction Stop; Good "cleared $v" }
        catch { Warn ("could not clear $v") }
    }
}

# ------------------------------------------------------------ 4. restore tasks
Step '4/6  Re-enable the update tasks'

foreach ($folder in $TaskFolders) {
    Get-ScheduledTask -TaskPath $folder -ErrorAction SilentlyContinue | ForEach-Object {
        $t = $_
        try {
            Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            Good ("task on: " + $t.TaskPath + $t.TaskName)
        } catch {
            Warn ("task still blocked: " + $t.TaskPath + $t.TaskName)
        }
    }
}

# The protected ones are only re-enable-able through their XML, which we may
# have flipped and backed up.
if (Test-Path $TaskBkDir) {
    $unicode = New-Object System.Text.UnicodeEncoding($false, $true)

    foreach ($dir in $TaskFileDirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_.FullName
            try {
                $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::Unicode)
            } catch { return }

            if ($raw -notmatch '(?i)<Enabled>\s*false\s*</Enabled>') { return }

            & icacls.exe $file /remove:d 'Administrators' 2>&1 | Out-Null
            & icacls.exe $file /grant '*S-1-5-32-544:F'   2>&1 | Out-Null

            try {
                $new = $raw -replace '(?i)<Enabled>\s*false\s*</Enabled>', '<Enabled>true</Enabled>'
                [System.IO.File]::WriteAllText($file, $new, $unicode)
                Good ("task on (xml): " + (Split-Path $file -Leaf))
            } catch {
                Warn ("could not re-enable " + (Split-Path $file -Leaf))
            }
        }
    }
}

# ----------------------------------------------------------- 5. normal flyout
Step '5/6  Put the power menu back to normal'

# 0xA = show both "Update and shut down" and "Update and restart" when an
# update is waiting. That is the Windows default.
$flyTarget = 10
$enhTarget = 1
if ($saved) {
    if ($null -ne $saved.FlyoutOptions)    { $flyTarget = [int]$saved.FlyoutOptions }
    if ($null -ne $saved.EnhancedShutdown) { $enhTarget = [int]$saved.EnhancedShutdown }
}

try {
    if (-not (Test-Path $OrchKey)) { New-Item -Path $OrchKey -Force | Out-Null }
    Set-ItemProperty -Path $OrchKey -Name 'ShutdownFlyoutOptions'   -Value $flyTarget -Type DWord -Force -ErrorAction Stop
    Good "ShutdownFlyoutOptions = $flyTarget"
    Set-ItemProperty -Path $OrchKey -Name 'EnhancedShutdownEnabled' -Value $enhTarget -Type DWord -Force -ErrorAction Stop
    Good "EnhancedShutdownEnabled = $enhTarget"
} catch { Warn ('flyout keys: ' + $_.Exception.Message) }

Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Good 'Start menu component recycled'

# -------------------------------------------------- 6. staged update leftovers
Step '6/6  Undo leftovers from a cancelled update'

$disabledXml = Join-Path $env:WINDIR 'WinSxS\pending.xml.disabled'
if (Test-Path $disabledXml) {
    Warn 'pending.xml.disabled found. Leaving it in place - it is inert, and the'
    Warn 'update re-downloads cleanly once you press Check for updates.'
}

# ---------------------------------------------------------------- verification
Step 'Reading the state back'

foreach ($s in $Services) {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    $v = (Get-ItemProperty $k -Name Start -ErrorAction SilentlyContinue).Start
    $st = (Get-Service $s -ErrorAction SilentlyContinue).Status
    Say ("  {0,-14} Start={1}  state={2}" -f $s, $v, $st)
}
Say ("  {0,-14} = {1}" -f 'FlyoutOptions', (Get-ItemProperty $OrchKey -Name 'ShutdownFlyoutOptions' -ErrorAction SilentlyContinue).ShutdownFlyoutOptions)

Say ''
Say ' Windows Update is back on. Open Settings > Windows Update > Check for updates.'
Say ' Reboot once so the update tasks actually reload.'
End-Script 0

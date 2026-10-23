#Requires -Version 5.1
<#
  stop-the-sucker.ps1

  Freezes Windows Update on Windows 10 / 11 and gives you back a normal
  Shut down / Restart button.

  Needs Administrator. Double-click stop-the-sucker.bat if you'd rather not
  open PowerShell yourself.

  Undo everything with start-updates.ps1.

  Options:
    -KeepStagedUpdate   Do not cancel an update that is already downloaded and
                        waiting for a reboot. By default a staged update IS
                        cancelled, because until it is, the power menu keeps
                        offering "Update and shut down".
#>
[CmdletBinding()]
param(
    [switch]$KeepStagedUpdate
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- bookkeeping
$StateDir  = Join-Path $env:ProgramData 'stop-the-sucker'
$StateFile = Join-Path $StateDir 'originals.json'
$TaskBkDir = Join-Path $StateDir 'task_backup'
New-Item -ItemType Directory -Path $StateDir  -Force | Out-Null
New-Item -ItemType Directory -Path $TaskBkDir -Force | Out-Null
$LogFile = Join-Path $StateDir ('stop-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
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

# ------------------------------------------------------------------- preamble
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Bad 'This needs Administrator rights.'
    Say '  Right-click stop-the-sucker.bat and choose "Run as administrator",'
    Say '  or open PowerShell as admin and run this file again.'
    End-Script 1
}

$version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Say '--------------------------------------------------------------'
Say ' stop the sucker - freezing Windows Update'
Say (' machine : ' + $env:COMPUTERNAME)
Say (' windows : ' + $version.CurrentBuild + '.' + $version.UBR + '  (' + $version.DisplayVersion + ')')
Say (' log     : ' + $LogFile)
Say '--------------------------------------------------------------'

$Services = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')

$PolicyKeys = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
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

# ---------------------------------------------------- capture the originals
$state = [ordered]@{
    CapturedAt                 = (Get-Date).ToString('o')
    Machine                    = $env:COMPUTERNAME
    Build                      = "$($version.CurrentBuild).$($version.UBR)"
    ServiceStart               = @{}
    FlyoutOptions              = $null
    EnhancedShutdown           = $null
    PausePreviouslySet         = @{}
}

foreach ($s in $Services) {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (Test-Path $k) {
        $state.ServiceStart[$s] = (Get-ItemProperty $k -Name Start -ErrorAction SilentlyContinue).Start
    }
}

$fo = (Get-ItemProperty $OrchKey -Name 'ShutdownFlyoutOptions'   -ErrorAction SilentlyContinue).ShutdownFlyoutOptions
$es = (Get-ItemProperty $OrchKey -Name 'EnhancedShutdownEnabled' -ErrorAction SilentlyContinue).EnhancedShutdownEnabled
$state.FlyoutOptions    = $fo
$state.EnhancedShutdown = $es

foreach ($v in $PauseVals) {
    $existing = (Get-ItemProperty $UxKey -Name $v -ErrorAction SilentlyContinue).$v
    if ($null -ne $existing) { $state.PausePreviouslySet[$v] = [string]$existing }
}

try {
    ($state | ConvertTo-Json -Depth 5) | Set-Content -Path $StateFile -Encoding UTF8
    Good "originals saved to $StateFile"
} catch {
    Warn ("could not save originals: " + $_.Exception.Message)
}

# ---------------------------------------------------------------- 1. services
Step '1/7  Park the update services'

foreach ($s in $Services) {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    if (-not (Test-Path $k)) { Warn "$s does not exist, skipping"; continue }

    try { Stop-Service -Name $s -Force -ErrorAction Stop; Good "$s stopped" }
    catch { Warn ("$s could not stop cleanly: " + $_.Exception.Message) }

    # Registry write, NOT 'sc config' - sc is refused for protected services.
    try {
        Set-ItemProperty -Path $k -Name Start -Value 4 -Type DWord -Force -ErrorAction Stop
        Good ("$s Start=4 (disabled) - was " + $state.ServiceStart[$s])
    } catch {
        Bad ("$s Start write failed: " + $_.Exception.Message)
    }
}

# ----------------------------------------------------------------- 2. policy
Step '2/7  Write the update policies'

# NOTE: Windows Home ignores most of these. They are here for Pro and they are
# harmless on Home. The services and the flyout key do the real work.
$policyValues = @(
    @($PolicyKeys[0], 'DoNotConnectToWindowsUpdateInternetLocations', 1),
    @($PolicyKeys[0], 'DisableWindowsUpdateAccess',                   1),
    @($PolicyKeys[1], 'NoAutoUpdate',                                 1),
    @($PolicyKeys[1], 'AUOptions',                                    1),
    @($PolicyKeys[1], 'NoAutoRebootWithLoggedOnUsers',                1),
    @($PolicyKeys[2], 'SearchOrderConfig',                            0)
)

foreach ($pv in $policyValues) {
    $path, $name, $value = $pv
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name $name -Value $value -Type DWord -Force -ErrorAction Stop
        Good "$name = $value"
    } catch {
        Warn ("$name failed: " + $_.Exception.Message)
    }
}

# ------------------------------------------------------------------ 3. pause
Step '3/7  Pause updates to 2099 (Home honours this even when it ignores policy)'

$utcNow = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$pauseValues = @(
    @('PauseFeatureUpdatesStartTime', $utcNow),
    @('PauseFeatureUpdatesEndTime',   '2099-12-31T00:00:00Z'),
    @('PauseQualityUpdatesStartTime', $utcNow),
    @('PauseQualityUpdatesEndTime',   '2099-12-31T00:00:00Z'),
    @('PauseUpdatesExpiryTime',       '2099-12-31T00:00:00Z')
)

foreach ($p in $pauseValues) {
    try {
        if (-not (Test-Path $UxKey)) { New-Item -Path $UxKey -Force | Out-Null }
        Set-ItemProperty -Path $UxKey -Name $p[0] -Value $p[1] -Type String -Force -ErrorAction Stop
        Good "$($p[0]) = $($p[1])"
    } catch {
        Warn ("$($p[0]) failed: " + $_.Exception.Message)
    }
}

# ------------------------------------------------------------------ 4. tasks
Step '4/7  Turn off the tasks that fire updates'

$failedTasks = @()

foreach ($folder in $TaskFolders) {
    $tasks = Get-ScheduledTask -TaskPath $folder -ErrorAction SilentlyContinue
    foreach ($t in $tasks) {
        try {
            Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            Good ("task off: " + $t.TaskPath + $t.TaskName)
        } catch {
            $failedTasks += $t
        }
    }
}

if ($failedTasks.Count -gt 0) {
    Warn ("$($failedTasks.Count) protected task(s) refused. Fixing ownership + ACL, then editing the XML.")

    foreach ($dir in $TaskFileDirs) {
        if (-not (Test-Path $dir)) { continue }
        & takeown.exe /f $dir /r /d y 2>&1 | Out-Null
        & icacls.exe  $dir /grant '*S-1-5-32-544:(OI)(CI)F' /t /c /q 2>&1 | Out-Null
    }

    $unicode = New-Object System.Text.UnicodeEncoding($false, $true)
    $targets = @()

    foreach ($dir in $TaskFileDirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $targets += $_.FullName
        }
    }

    foreach ($file in $targets) {
        $leaf = Split-Path $file -Leaf
        try {
            # Task files are UTF-16LE with a BOM. A UTF-8 write corrupts them.
            $raw = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::Unicode)
        } catch { continue }

        if ($raw -notmatch '(?i)<Enabled>\s*true\s*</Enabled>') { continue }

        # Administrators are only granted (RX) on these files - strip the deny
        # ACEs before trying to write, or the write is refused even as owner.
        & icacls.exe $file /remove:d 'Administrators' 2>&1 | Out-Null
        & icacls.exe $file /remove:d 'Everyone'       2>&1 | Out-Null
        & icacls.exe $file /remove:d 'Users'          2>&1 | Out-Null
        & icacls.exe $file /remove:d 'SYSTEM'         2>&1 | Out-Null
        & icacls.exe $file /grant '*S-1-5-32-544:F'   2>&1 | Out-Null
        & icacls.exe $file /setowner '*S-1-5-32-544'  2>&1 | Out-Null

        try {
            Copy-Item -LiteralPath $file -Destination (Join-Path $TaskBkDir $leaf) -Force -ErrorAction SilentlyContinue
            $new = $raw -replace '(?i)<Enabled>\s*true\s*</Enabled>', '<Enabled>false</Enabled>'
            [System.IO.File]::WriteAllText($file, $new, $unicode)
            Good "task off (xml): $leaf"
        } catch {
            Bad ("task xml write failed: $leaf -> " + $_.Exception.Message)
        }
    }

    Warn 'Task Scheduler caches task state. The list still says "Ready" until you reboot -'
    Warn 'the files on disk already say disabled. Do not chase it.'
}

# ----------------------------------------------------------------- 5. flyout
Step '5/7  Fix the power menu (the bit that actually annoys people)'

# This is the real driver of "Update and shut down" / "Update and restart".
# Clearing CBS flags does NOT remove them. 0xA means "show both update entries".
try {
    if (-not (Test-Path $OrchKey)) { New-Item -Path $OrchKey -Force | Out-Null }
    Set-ItemProperty -Path $OrchKey -Name 'ShutdownFlyoutOptions'   -Value 0 -Type DWord -Force -ErrorAction Stop
    Good ("ShutdownFlyoutOptions = 0 (was " + $fo + ")")
    Set-ItemProperty -Path $OrchKey -Name 'EnhancedShutdownEnabled' -Value 0 -Type DWord -Force -ErrorAction Stop
    Good ("EnhancedShutdownEnabled = 0 (was " + $es + ")")
} catch {
    Bad ("flyout keys failed: " + $_.Exception.Message)
}

# USO rewrites that value whenever it is awake. Confirm it stuck and re-assert
# once. This is exactly why the services get stopped in step 1, before here -
# if you set the flyout while UsoSvc is running it silently goes back to 0xA.
Start-Sleep -Seconds 3
$flyAfter = (Get-ItemProperty $OrchKey -Name 'ShutdownFlyoutOptions' -ErrorAction SilentlyContinue).ShutdownFlyoutOptions
if ($null -eq $flyAfter) {
    Warn 'could not read ShutdownFlyoutOptions back'
} elseif ($flyAfter -ne 0) {
    Warn ("Update Orchestrator rewrote ShutdownFlyoutOptions to $flyAfter - re-asserting 0")
    try {
        Set-ItemProperty -Path $OrchKey -Name 'ShutdownFlyoutOptions' -Value 0 -Type DWord -Force -ErrorAction Stop
        Good 'ShutdownFlyoutOptions re-asserted to 0'
    } catch { Bad 'could not re-assert ShutdownFlyoutOptions' }
} else {
    Good 'ShutdownFlyoutOptions held at 0'
}

try {
    Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Good 'Start menu component recycled (it restarts on the next Start press)'
} catch { Warn 'could not recycle the Start menu component' }

# --------------------------------------------------------- 6. staged update
Step '6/7  Cancel an update that is already staged'

if ($KeepStagedUpdate) {
    Warn 'skipped (-KeepStagedUpdate). The power menu may keep offering Update and shut down.'
} else {
    $pendingXml = Join-Path $env:WINDIR 'WinSxS\pending.xml'

    if (Test-Path $pendingXml) {
        $sizeMb = [math]::Round((Get-Item $pendingXml).Length / 1MB, 1)
        Warn "a staged update exists (pending.xml, $sizeMb MB). Cancelling it."

        # Supported revert. Works online on Win11 even though the docs point at
        # offline images. It consumes pending.xml itself.
        $dism = & dism.exe /Online /Cleanup-Image /RevertPendingActions 2>&1
        $dism | ForEach-Object { Say ("        " + $_) }

        if ($LASTEXITCODE -eq 0) {
            Good 'DISM reverted the pending transaction'
        } else {
            Warn 'DISM declined. Renaming pending.xml out of the way instead.'
            & takeown.exe /f $pendingXml 2>&1 | Out-Null
            & icacls.exe  $pendingXml /remove:d 'Administrators' 2>&1 | Out-Null
            & icacls.exe  $pendingXml /grant '*S-1-5-32-544:F'   2>&1 | Out-Null
            try {
                Move-Item -LiteralPath $pendingXml -Destination ($pendingXml + '.disabled') -Force -ErrorAction Stop
                Good 'pending.xml renamed to pending.xml.disabled'
            } catch {
                Bad ('could not move pending.xml: ' + $_.Exception.Message)
            }
        }
    } else {
        Good 'nothing staged - no pending.xml'
    }

    # Clear the reboot markers so the power menu settles.
    $markers = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
    )
    foreach ($m in $markers) {
        if (Test-Path $m) {
            try { Remove-Item $m -Recurse -Force -ErrorAction Stop; Good ('removed ' + (Split-Path $m -Leaf)) }
            catch { Warn ((Split-Path $m -Leaf) + ' is locked (this is normal)') }
        }
    }

    # Free the download cache. Usually hundreds of MB.
    $dl = Join-Path $env:WINDIR 'SoftwareDistribution\Download'
    if (Test-Path $dl) {
        try {
            Get-ChildItem $dl -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $left = (Get-ChildItem $dl -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Good ('download cache cleared, ' + [math]::Round(($left / 1MB), 1) + ' MB left')
        } catch { Warn 'could not fully clear the download cache' }
    }
}

# ------------------------------------------------------------- 7. verification
Step '7/7  Read the state back'

foreach ($s in $Services) {
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    $v = (Get-ItemProperty $k -Name Start -ErrorAction SilentlyContinue).Start
    $st = (Get-Service $s -ErrorAction SilentlyContinue).Status
    Say ("  {0,-14} Start={1}  state={2}" -f $s, $v, $st)
}

Say ("  {0,-14} = {1}" -f 'FlyoutOptions', (Get-ItemProperty $OrchKey -Name 'ShutdownFlyoutOptions' -ErrorAction SilentlyContinue).ShutdownFlyoutOptions)
Say ("  {0,-14} = {1}" -f 'PendingXml',   (Test-Path (Join-Path $env:WINDIR 'WinSxS\pending.xml')))
Say ("  {0,-14} = {1}" -f 'Build',        "$($version.CurrentBuild).$($version.UBR)")

$taskStates = @()
foreach ($folder in $TaskFolders) {
    $taskStates += Get-ScheduledTask -TaskPath $folder -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty State
}
$enabled = ($taskStates | Where-Object { $_ -ne 'Disabled' }).Count
Say ("  update tasks still enabled : {0} (may show stale until reboot)" -f $enabled)

Say ''
Say ' Done. Shut down / Restart are normal buttons again.'
Say ' Undo any time with:  start-updates.ps1'
Say (' Archived originals:   ' + $StateFile)
End-Script 0

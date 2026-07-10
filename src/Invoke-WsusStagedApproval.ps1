[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WsusServerName,

    [int]$WsusPort = 8530,
    [switch]$UseSsl,
    [string]$LogPath = (Join-Path $PSScriptRoot '..\\data\\wsus-staged-approval.log'),
    [string]$StatePath = (Join-Path $PSScriptRoot '..\\data\\wsus-cycle-state.json'),
    [string]$DeploymentPlanPath = (Join-Path $PSScriptRoot '..\\config\\deployment-plan.json'),
    # Only use when deliberately restarting the current month's state tracking.
    [switch]$ResetCycle
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $line
}

function Get-PatchWednesday {
    param([datetime]$ReferenceDate = (Get-Date))
    $firstDay = Get-Date -Year $ReferenceDate.Year -Month $ReferenceDate.Month -Day 1
    $daysUntilTuesday = (([int][DayOfWeek]::Tuesday - [int]$firstDay.DayOfWeek) + 7) % 7
    # Patch Tuesday in US time normally falls on Wednesday in Taiwan time.
    $firstDay.AddDays($daysUntilTuesday + 8).Date
}

function New-CycleState {
    param([string]$CycleMonth, [datetime]$PatchDay)
    [pscustomobject][ordered]@{
        SchemaVersion = 1; CycleMonth = $CycleMonth; PatchDay = $PatchDay.ToString('yyyy-MM-dd')
        Status = 'WaitingForUpdate'; CycleStartDate = $null; CompletedDate = $null
        UpdateIds = @(); LastUpdated = (Get-Date).ToString('s')
    }
}

function Save-CycleState {
    param($State)
    $State.LastUpdated = (Get-Date).ToString('s')
    $tempPath = "$StatePath.tmp"
    [IO.File]::WriteAllText($tempPath, ($State | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
    Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
}

function Test-IsTargetUpdate {
    param($Update)
    $text = "$($Update.Title) $(@($Update.ProductTitles) -join ' | ')"
    !$Update.IsDeclined -and $Update.IsLatestRevision -and !$Update.IsSuperseded -and
    $text -match '(?i)(Windows 11|Office 2016)'
}

function Ensure-InstallApproval {
    param($Update, $Group)
    $install = [Microsoft.UpdateServices.Administration.UpdateApprovalAction]::Install
    if (@($Update.GetUpdateApprovals($Group) | Where-Object Action -eq $install).Count -gt 0) { return $false }
    [void]$Update.Approve($install, $Group)
    $true
}

$logDirectory = Split-Path -Parent $LogPath
$stateDirectory = Split-Path -Parent $StatePath
foreach ($directory in @($logDirectory, $stateDirectory)) {
    if ($directory -and !(Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
}
if (!(Test-Path -LiteralPath $DeploymentPlanPath)) { throw "Deployment plan not found: $DeploymentPlanPath" }
$deploymentPlan = @(Get-Content -LiteralPath $DeploymentPlanPath -Raw | ConvertFrom-Json)

try {
    Add-Type -Path 'C:\Program Files\Update Services\API\Microsoft.UpdateServices.Administration.dll'
    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($WsusServerName, $UseSsl.IsPresent, $WsusPort)
    Write-Log "Connected to WSUS: $($wsus.Name)"
} catch { throw "Unable to connect to WSUS: $($_.Exception.Message)" }

$today = (Get-Date).Date
$patchDay = Get-PatchWednesday $today
if ($today -lt $patchDay) { Write-Log "Before Patch Wednesday ($($patchDay.ToString('yyyy-MM-dd'))); no action."; return }

if ($ResetCycle -and (Test-Path -LiteralPath $StatePath)) { Remove-Item -LiteralPath $StatePath -Force; Write-Log 'Cycle state reset. Existing approvals were not revoked.' }
$cycleMonth = $today.ToString('yyyy-MM')
$state = if (Test-Path $StatePath) { Get-Content $StatePath -Raw | ConvertFrom-Json } else { $null }
if (!$state -or $state.SchemaVersion -ne 1 -or $state.CycleMonth -ne $cycleMonth) { $state = New-CycleState $cycleMonth $patchDay; Save-CycleState $state }
if ($state.Status -eq 'Completed') { Write-Log 'This month is already complete.'; return }

if ($state.Status -ne 'Dispatching') {
    $scope = [Microsoft.UpdateServices.Administration.UpdateScope]::new()
    $scope.FromArrivalDate = $patchDay; $scope.ToArrivalDate = Get-Date
    $updates = @($wsus.GetUpdates($scope) | Where-Object { Test-IsTargetUpdate $_ } | Sort-Object ArrivalDate)
    if (!$updates) { Write-Log 'No matching updates found yet.'; return }
    $notReady = @($updates | Where-Object { $_.Refresh(); $_.State.ToString() -ne 'Ready' })
    if ($notReady) { Write-Log "$($notReady.Count) update(s) are not ready; no groups approved."; return }
    $state.Status = 'Dispatching'; $state.CycleStartDate = $today.ToString('yyyy-MM-dd')
    $state.UpdateIds = @($updates | ForEach-Object { $_.Id.UpdateId.ToString() } | Select-Object -Unique); Save-CycleState $state
} else {
    $updates = foreach ($id in @($state.UpdateIds)) { $wsus.GetUpdate([Microsoft.UpdateServices.Administration.UpdateRevisionId]::new([guid]$id, 0)) }
}

$d0 = [datetime]::ParseExact($state.CycleStartDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$day = [Math]::Min((($today - $d0.Date).Days), 9)
$groups = @($wsus.GetComputerTargetGroups())
foreach ($entry in $deploymentPlan | Where-Object { $_.Day -le $day }) {
    $matches = @($groups | Where-Object Name -eq $entry.Name)
    if ($matches.Count -ne 1) { Write-Log "Expected exactly one group named '$($entry.Name)'; skipping."; continue }
    foreach ($update in $updates) {
        $update.Refresh()
        if (!$update.IsDeclined -and !$update.IsSuperseded -and (Ensure-InstallApproval $update $matches[0])) { Write-Log "Approved '$($update.Title)' for $($entry.Name)" }
    }
}
if ((($today - $d0.Date).Days) -ge 9) { $state.Status = 'Completed'; $state.CompletedDate = $today.ToString('yyyy-MM-dd') }
Save-CycleState $state
Write-Log "Deployment run for D$day completed."

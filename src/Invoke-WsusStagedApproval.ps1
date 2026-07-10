[CmdletBinding()]
param(
    # 測試或重新開始當月流程時使用；不會撤銷既有的 WSUS 核准。
    [switch]$ResetCycle
)

# =========================
# WSUS 自動分批核准系統
# =========================
# 流程：
# 1. 美國每月第二個星期二的隔天（台灣 Patch Wednesday）之後，才偵測新更新。
# 2. 沿用 WSUS 既有下載設定，不建立群組，也不做任何預先核准。
# 3. 所有目標更新都成為 Ready 後，才把當天記為 D0 並開始分批派送。

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ===== 基本設定（請依自己的環境修改） =====
$WsusServerName  = "YOUR-WSUS-SERVER"
$UseSsl          = $false
$WsusPort        = 8530
$LogPath         = "C:\ProgramData\WsusStagedApproval\wsus.log"
$StatePath       = "C:\ProgramData\WsusStagedApproval\wsus-cycle-state.json"

# 目標產品關鍵字：同時比對 WSUS 產品名稱與更新標題，不分大小寫。
# 可依環境增加或刪除，例如：Windows 10、Windows Server 2022、Microsoft 365 Apps。
$TargetProductKeywords = @(
    "Windows 11",
    "Office 2016",
    "Excel 2016",
    "Word 2016",
    "PowerPoint 2016"
)

$TargetProductKeywords = @(
    $TargetProductKeywords |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { ([string]$_).Trim() } |
        Select-Object -Unique
)

if ($TargetProductKeywords.Count -eq 0) {
    throw "TargetProductKeywords 至少需要設定一個產品關鍵字。"
}

$targetProductSummary = $TargetProductKeywords -join "／"

# ===== Log =====
$logDirectory = Split-Path -Parent $LogPath

if (!(Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $line
}

# ===== WSUS API 與連線 =====
try {
    Add-Type -Path "C:\Program Files\Update Services\API\Microsoft.UpdateServices.Administration.dll"

    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer(
        $WsusServerName,
        $UseSsl,
        $WsusPort
    )

    Write-Log "WSUS 連線成功：$($wsus.Name)"
}
catch {
    Write-Log "WSUS 連線失敗：$($_.Exception.Message)"
    exit 1
}

# =========================
# 日期與狀態檔函式
# =========================
function Get-PatchWednesday {
    param([datetime]$ReferenceDate = (Get-Date))

    $firstDay = Get-Date -Year $ReferenceDate.Year -Month $ReferenceDate.Month -Day 1
    $daysUntilTuesday = (([int][System.DayOfWeek]::Tuesday - [int]$firstDay.DayOfWeek) + 7) % 7
    $secondTuesday = $firstDay.AddDays($daysUntilTuesday + 7).Date

    # Microsoft 於美國時間第二個星期二發布；換算台灣時間為隔天星期三。
    return $secondTuesday.AddDays(1).Date
}

function New-CycleState {
    param(
        [Parameter(Mandatory = $true)][string]$CycleMonth,
        [Parameter(Mandatory = $true)][datetime]$PatchDay
    )

    return [pscustomobject][ordered]@{
        SchemaVersion  = 3
        CycleMonth     = $CycleMonth
        PatchDay       = $PatchDay.ToString("yyyy-MM-dd")
        Status         = "WaitingForUpdate"
        CycleStartDate = $null
        CompletedDate  = $null
        UpdateIds      = @()
        LastUpdated    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

function Save-CycleState {
    param([Parameter(Mandatory = $true)]$State)

    $State.LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $json = $State | ConvertTo-Json -Depth 5
    $tempPath = "$StatePath.tmp"
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)

    [System.IO.File]::WriteAllText($tempPath, $json, $utf8WithBom)
    Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
}

function Read-CycleState {
    if (!(Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
    }
    catch {
        throw "狀態檔讀取失敗：$($_.Exception.Message)"
    }
}

# =========================
# 更新篩選與 WSUS 輔助函式
# =========================
function Test-IsTargetUpdate {
    param([Parameter(Mandatory = $true)]$Update)

    $title = [string]$Update.Title
    $productText = (@($Update.ProductTitles) -join " | ")

    $matchesTargetProduct = $false

    foreach ($keyword in $TargetProductKeywords) {
        $matchesProductName = $productText.IndexOf(
            $keyword,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0

        $matchesTitle = $title.IndexOf(
            $keyword,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0

        if ($matchesProductName -or $matchesTitle) {
            $matchesTargetProduct = $true
            break
        }
    }

    return (
        !$Update.IsDeclined -and
        $Update.IsLatestRevision -and
        !$Update.IsSuperseded -and
        $matchesTargetProduct
    )
}

function Get-NewTargetUpdates {
    param(
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)][datetime]$FromDate
    )

    $scope = New-Object Microsoft.UpdateServices.Administration.UpdateScope
    $scope.FromArrivalDate = $FromDate
    $scope.ToArrivalDate = Get-Date

    $allNewUpdates = @($Server.GetUpdates($scope))
    $targetUpdates = @($allNewUpdates | Where-Object { Test-IsTargetUpdate -Update $_ })
    return @($targetUpdates | Sort-Object ArrivalDate)
}

function Get-UpdatesFromState {
    param(
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)]$UpdateIds
    )

    $result = @()

    foreach ($updateIdText in @($UpdateIds)) {
        try {
            # RevisionNumber 0 代表取得該 UpdateId 的最新修訂版。
            $revisionId = New-Object -TypeName Microsoft.UpdateServices.Administration.UpdateRevisionId -ArgumentList ([guid]$updateIdText), 0
            $result += $Server.GetUpdate($revisionId)
        }
        catch {
            throw "無法從 WSUS 取得更新 $updateIdText：$($_.Exception.Message)"
        }
    }

    return @($result)
}

function Ensure-InstallApproval {
    param(
        [Parameter(Mandatory = $true)]$Update,
        [Parameter(Mandatory = $true)]$Group
    )

    $installAction = [Microsoft.UpdateServices.Administration.UpdateApprovalAction]::Install
    $existingApproval = @(
        $Update.GetUpdateApprovals($Group) |
            Where-Object { $_.Action -eq $installAction }
    ) | Select-Object -First 1

    if ($existingApproval) {
        return $false
    }

    [void]$Update.Approve($installAction, $Group)
    return $true
}

# =========================
# 群組定義（範例名稱，請改成自己的既有 WSUS 群組）
# =========================
$deptTable = @(
    @{ Name = "IT-Pilot";         Day = 0 },
    @{ Name = "Department-A";     Day = 1 },
    @{ Name = "Branch-01";        Day = 2 },
    @{ Name = "Branch-02";        Day = 3 },
    @{ Name = "Branch-03";        Day = 4 },
    @{ Name = "Branch-04";        Day = 5 },
    @{ Name = "Branch-05";        Day = 6 },
    @{ Name = "Site-01";          Day = 7 },
    @{ Name = "Site-02";          Day = 8 },
    @{ Name = "Remote-Site";      Day = 9 }
)

# =========================
# Patch Wednesday 與當月狀態
# =========================
$today = (Get-Date).Date
$patchDay = Get-PatchWednesday -ReferenceDate $today
$cycleMonth = $today.ToString("yyyy-MM")

Write-Log "本月 Patch Wednesday（第二個星期二加一天）：$($patchDay.ToString('yyyy-MM-dd'))"

if ($today -lt $patchDay) {
    Write-Log "尚未到 Patch Wednesday，不執行"
    exit 0
}

if ($ResetCycle -and (Test-Path -LiteralPath $StatePath)) {
    Remove-Item -LiteralPath $StatePath -Force
    Write-Log "已依參數重設當月週期狀態；既有 WSUS 核准不會被撤銷"
}

try {
    $cycleState = Read-CycleState
}
catch {
    Write-Log $_.Exception.Message
    exit 1
}

$stateSchemaVersion = $null
if ($cycleState -and $cycleState.PSObject.Properties["SchemaVersion"]) {
    $stateSchemaVersion = $cycleState.SchemaVersion
}

if (
    -not $cycleState -or
    $stateSchemaVersion -ne 3 -or
    $cycleState.CycleMonth -ne $cycleMonth
) {
    $cycleState = New-CycleState -CycleMonth $cycleMonth -PatchDay $patchDay
    Save-CycleState -State $cycleState
}

if ($cycleState.Status -eq "Completed") {
    Write-Log "本月 Patch 週期已於 $($cycleState.CompletedDate) 完成，不再執行"
    exit 0
}

# ===== 取得現有 WSUS 群組；本腳本不建立或修改群組結構 =====
$allGroups = @($wsus.GetComputerTargetGroups())

# =========================
# 等待新更新與下載完成閘門
# =========================
if ($cycleState.Status -ne "Dispatching") {
    try {
        $newUpdates = @(Get-NewTargetUpdates -Server $wsus -FromDate $patchDay)
    }
    catch {
        Write-Log "查詢本月新更新失敗：$($_.Exception.Message)"
        exit 1
    }

    if ($newUpdates.Count -eq 0) {
        $cycleState.Status = "WaitingForUpdate"
        $cycleState.UpdateIds = @()
        Save-CycleState -State $cycleState

        Write-Log "本月尚未偵測到新的目標產品更新（$targetProductSummary），等待下次執行"
        exit 0
    }

    $cycleState.Status = "Downloading"
    $cycleState.UpdateIds = @(
        $newUpdates |
            ForEach-Object { $_.Id.UpdateId.ToString() } |
            Select-Object -Unique
    )
    Save-CycleState -State $cycleState

    Write-Log "已偵測到 $($newUpdates.Count) 筆本月目標更新"

    try {
        $serverConfiguration = $wsus.GetConfiguration()

        if ($serverConfiguration.HostBinariesOnMicrosoftUpdate) {
            throw "目前設定為由用戶端直接向 Microsoft Update 下載檔案，WSUS 本機沒有內容檔可供本腳本驗證。"
        }

        if ($serverConfiguration.DownloadUpdateBinariesAsNeeded) {
            Write-Log "WSUS 目前設定為核准後才下載；本腳本不會建立暫存群組或預先核准，將等待你既有的 WSUS 設定完成下載"
        }

        $downloadProgress = $wsus.GetContentDownloadProgress()
        Write-Log "WSUS 整體內容下載進度：$($downloadProgress.DownloadedBytes) / $($downloadProgress.TotalBytesToDownload) Bytes"
    }
    catch {
        Write-Log "讀取 WSUS 下載設定或進度失敗：$($_.Exception.Message)"
        exit 1
    }

    $notReadyUpdates = @()

    foreach ($update in $newUpdates) {
        try {
            [void]$update.Refresh()
            $updateState = $update.State.ToString()

            if ($updateState -eq "Ready") {
                Write-Log "更新內容已下載完成：$($update.Title)"
            }
            elseif ($updateState -eq "Failed" -or $updateState -eq "Canceled") {
                Write-Log "更新下載異常，等待 WSUS 端處理：$($update.Title)（狀態：$updateState）"
                $notReadyUpdates += $update
            }
            else {
                Write-Log "更新尚未下載完成：$($update.Title)（狀態：$updateState）"
                $notReadyUpdates += $update
            }
        }
        catch {
            Write-Log "檢查下載狀態失敗：$($update.Title)；$($_.Exception.Message)"
            $notReadyUpdates += $update
        }
    }

    if ($notReadyUpdates.Count -gt 0) {
        try {
            $downloadProgress = $wsus.GetContentDownloadProgress()
            Write-Log "目前 WSUS 整體內容下載進度：$($downloadProgress.DownloadedBytes) / $($downloadProgress.TotalBytesToDownload) Bytes"
        }
        catch {
            Write-Log "無法再次取得 WSUS 下載進度：$($_.Exception.Message)"
        }

        Save-CycleState -State $cycleState
        Write-Log "尚有 $($notReadyUpdates.Count) 筆目標更新未完成下載，本次不核准任何正式群組"
        exit 0
    }

    $cycleState.Status = "Dispatching"
    $cycleState.CycleStartDate = $today.ToString("yyyy-MM-dd")
    Save-CycleState -State $cycleState

    Write-Log "全部 $($newUpdates.Count) 筆目標更新均已下載完成；今天起算為 D0"
    $updates = @($newUpdates)
}
else {
    try {
        $updates = @(Get-UpdatesFromState -Server $wsus -UpdateIds $cycleState.UpdateIds)
    }
    catch {
        Write-Log "讀取當月更新清單失敗：$($_.Exception.Message)"
        exit 1
    }
}

if ($updates.Count -eq 0) {
    Write-Log "當月派送清單為空，為避免誤核准，腳本停止"
    exit 1
}

# =========================
# 以實際下載完成日計算 D0～D9
# =========================
try {
    $cycleStartDate = [datetime]::ParseExact(
        [string]$cycleState.CycleStartDate,
        "yyyy-MM-dd",
        [System.Globalization.CultureInfo]::InvariantCulture
    ).Date
}
catch {
    Write-Log "D0 起始日格式錯誤，腳本停止：$($_.Exception.Message)"
    exit 1
}

$offset = ($today - $cycleStartDate).Days

if ($offset -lt 0) {
    Write-Log "目前日期早於 D0 起始日，腳本停止"
    exit 1
}

$dispatchDay = [Math]::Min($offset, 9)
Write-Log "目前實際派送週期：D$dispatchDay（D0：$($cycleStartDate.ToString('yyyy-MM-dd'))）"

# =========================
# 正式群組核准流程
# =========================
$approvalErrors = 0

foreach ($dept in $deptTable) {
    if ($dept.Day -gt $dispatchDay) {
        continue
    }

    $groupMatches = @($allGroups | Where-Object { $_.Name -eq $dept.Name })

    if ($groupMatches.Count -eq 0) {
        Write-Log "找不到 WSUS 群組：$($dept.Name)"
        $approvalErrors++
        continue
    }

    if ($groupMatches.Count -gt 1) {
        Write-Log "找到多個同名 WSUS 群組：$($dept.Name)，為避免選錯群組，本次跳過"
        $approvalErrors++
        continue
    }

    $group = $groupMatches[0]
    $newApprovalCount = 0

    foreach ($update in $updates) {
        try {
            [void]$update.Refresh()

            if ($update.IsDeclined -or $update.IsSuperseded) {
                Write-Log "略過已拒絕或已被取代的更新：$($update.Title)"
                continue
            }

            $created = Ensure-InstallApproval -Update $update -Group $group
            if ($created) {
                $newApprovalCount++
                Write-Log "已核准至 $($dept.Name)：$($update.Title)"
            }
        }
        catch {
            Write-Log "核准失敗：群組=$($dept.Name)；更新=$($update.Title)；錯誤=$($_.Exception.Message)"
            $approvalErrors++
        }
    }

    if ($newApprovalCount -eq 0) {
        Write-Log "群組 $($dept.Name) 無新增核准（既有核准會保留）"
    }
    else {
        Write-Log "群組 $($dept.Name) 本次新增 $newApprovalCount 筆核准"
    }

    Write-Host ""
}

if ($approvalErrors -gt 0) {
    Save-CycleState -State $cycleState
    Write-Log "本次共有 $approvalErrors 筆群組或更新處理錯誤；下次執行會重試"
    exit 1
}

if ($offset -ge 9) {
    $cycleState.Status = "Completed"
    $cycleState.CompletedDate = $today.ToString("yyyy-MM-dd")
    Save-CycleState -State $cycleState
    Write-Log "本月 D0～D9 分批核准作業已全部完成"
}
else {
    Save-CycleState -State $cycleState
    Write-Log "WSUS D$dispatchDay 分批核准作業執行完成"
}

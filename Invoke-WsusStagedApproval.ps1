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
# 4. Windows 11 依 D0～D10 分批；Windows Server 於 D10 派送。

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ===== 基本設定（請依自己的環境修改） =====
$WsusServerName  = "YOUR-WSUS-SERVER"
$UseSsl          = $false
$WsusPort        = 8530
$LogPath         = "C:\ProgramData\WsusStagedApproval\wsus.log"
$StatePath       = "C:\ProgramData\WsusStagedApproval\wsus-cycle-state.json"
$DeadlineTimeZoneId = "Taipei Standard Time"

try {
    $DeadlineTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($DeadlineTimeZoneId)
}
catch {
    throw "無法載入 Deadline 時區 $DeadlineTimeZoneId：$($_.Exception.Message)"
}

# 目標產品關鍵字：同時比對 WSUS 產品名稱與更新標題，不分大小寫。
# Office 2016 已從自動核准範圍移除。
$ClientProductKeywords = @(
    "Windows 11"
)

$ServerProductKeywords = @(
    "Microsoft Server operating system-21H2",
    "Windows Server 2016",
    "Windows Server 2019"
)

$TargetProductKeywords = @(
    $ClientProductKeywords
    $ServerProductKeywords
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

function Write-LogSection {
    param([Parameter(Mandatory = $true)][string]$Title)

    $separator = "=" * 72

    Add-Content -LiteralPath $LogPath -Value ""
    Add-Content -LiteralPath $LogPath -Value $separator
    Write-Host ""
    Write-Host $separator

    Write-Log "【$Title】"

    Add-Content -LiteralPath $LogPath -Value $separator
    Write-Host $separator
}

Write-LogSection -Title "開始執行 WSUS 自動分批核准作業"
Write-Log "Deadline 時區：$DeadlineTimeZoneId（UTC+08:00）"

# ===== WSUS API 與連線 =====
try {
    Add-Type -Path "C:\Program Files\Update Services\API\Microsoft.UpdateServices.Administration.dll"

    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer(
        $WsusServerName,
        $UseSsl,
        $WsusPort
    )

    $serverConfiguration = $wsus.GetConfiguration()
    $currentWsusServerId = $serverConfiguration.ServerId.ToString()

    Write-Log "WSUS 連線成功：$($wsus.Name)"
    Write-Log "WSUS 伺服器識別碼：$currentWsusServerId"
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
        [Parameter(Mandatory = $true)][datetime]$PatchDay,
        [Parameter(Mandatory = $true)][string]$WsusServerId
    )

    return [pscustomobject][ordered]@{
        SchemaVersion  = 5
        WsusServerId   = $WsusServerId
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
function Test-UpdateMatchesKeywords {
    param(
        [Parameter(Mandatory = $true)]$Update,
        [Parameter(Mandatory = $true)][string[]]$Keywords
    )

    $title = [string]$Update.Title
    $productText = (@($Update.ProductTitles) -join " | ")

    foreach ($keyword in $Keywords) {
        $matchesProductName = $productText.IndexOf(
            $keyword,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0

        $matchesTitle = $title.IndexOf(
            $keyword,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0

        if ($matchesProductName -or $matchesTitle) {
            return $true
        }
    }

    return $false
}

function Test-IsTargetUpdate {
    param([Parameter(Mandatory = $true)]$Update)

    $matchesTargetProduct = Test-UpdateMatchesKeywords -Update $Update -Keywords $TargetProductKeywords

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

    # WSUS 重裝後，舊更新的 ArrivalDate 可能會變成重新同步的日期。
    # 再限制為 Patch Wednesday 前 7 天以後建立的更新，避免誤抓大量歷史更新。
    $scope.FromCreationDate = $FromDate.AddDays(-7)
    $scope.ToCreationDate = Get-Date

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
    $missingIds = @()

    foreach ($updateIdText in @($UpdateIds)) {
        try {
            # RevisionNumber 0 代表取得該 UpdateId 的最新修訂版。
            $revisionId = New-Object -TypeName Microsoft.UpdateServices.Administration.UpdateRevisionId -ArgumentList ([guid]$updateIdText), 0
            $result += $Server.GetUpdate($revisionId)
        }
        catch [Microsoft.UpdateServices.Administration.WsusObjectNotFoundException] {
            $missingIds += [string]$updateIdText
        }
        catch {
            throw "無法從 WSUS 取得更新 $updateIdText：$($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        Updates    = @($result)
        MissingIds = @($missingIds)
    }
}

function Ensure-InstallApproval {
    param(
        [Parameter(Mandatory = $true)]$Update,
        [Parameter(Mandatory = $true)]$Group,
        [Parameter(Mandatory = $true)][datetime]$DeadlineUtc
    )

    $installAction = [Microsoft.UpdateServices.Administration.UpdateApprovalAction]::Install
    $existingApproval = @(
        $Update.GetUpdateApprovals($Group) |
            Where-Object { $_.Action -eq $installAction }
    ) | Select-Object -First 1

    if ($existingApproval) {
        # 只要該更新對群組已有 Install 核准，保留原核准與原 Deadline。
        return "AlreadyApproved"
    }

    [void]$Update.Approve($installAction, $Group, $DeadlineUtc)
    return "Created"
}

# =========================
# 群組定義（公開範例名稱，請改成自己的既有 WSUS 群組）
# =========================
$deptTable = @(
    # Windows 11：D0～D10，各組 Deadline 為當日 12:15。
    @{ Name = "IT-Pilot";            Day = 0;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Headquarters-A";      Day = 1;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Headquarters-B";      Day = 1;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Branch-01";           Day = 2;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Branch-02";           Day = 3;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Branch-03";           Day = 4;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Branch-04";           Day = 5;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Branch-05";           Day = 6;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Site-01";             Day = 7;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Site-02";             Day = 8;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Remote-Site";         Day = 9;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Unassigned Computers"; Day = 10; Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Client-Fallback";     Day = 10; Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },

    # Windows Server：D10，Deadline 為台灣時間下午 17:30。
    @{ Name = "Server-Pilot";        Day = 10; Scope = "Server"; DeadlineHour = 17; DeadlineMinute = 30 },
    @{ Name = "Server-Production";   Day = 10; Scope = "Server"; DeadlineHour = 17; DeadlineMinute = 30 }
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
$stateWsusServerId = $null
if ($cycleState -and $cycleState.PSObject.Properties["SchemaVersion"]) {
    $stateSchemaVersion = $cycleState.SchemaVersion
}
if ($cycleState -and $cycleState.PSObject.Properties["WsusServerId"]) {
    $stateWsusServerId = [string]$cycleState.WsusServerId
}

$resetReason = $null

if (-not $cycleState) {
    $resetReason = "找不到既有週期狀態"
}
elseif ($stateSchemaVersion -ne 5) {
    $resetReason = "狀態檔版本已更新"
}
elseif ($stateWsusServerId -ne $currentWsusServerId) {
    $resetReason = "偵測到 WSUS 已重裝或更換 SUSDB"
}
elseif ($cycleState.CycleMonth -ne $cycleMonth) {
    $resetReason = "進入新的月份"
}

if ($resetReason) {
    Write-Log "$resetReason，將重建 $cycleMonth 的週期狀態"
    $cycleState = New-CycleState -CycleMonth $cycleMonth -PatchDay $patchDay -WsusServerId $currentWsusServerId
    Save-CycleState -State $cycleState
}

if ($cycleState.Status -eq "Completed") {
    Write-Log "本月 Patch 週期已於 $($cycleState.CompletedDate) 完成，不再執行"
    exit 0
}

# ===== 取得現有 WSUS 群組；本腳本不建立或修改群組結構 =====
$allGroups = @($wsus.GetComputerTargetGroups())

# WSUS 自動核准規則可與腳本並存；已有核准會保留並略過。
$enabledAutomaticRules = @()
try {
    $enabledAutomaticRules = @($wsus.GetInstallApprovalRules() | Where-Object { $_.Enabled })
}
catch {
    Write-Log "警告：檢查 WSUS 自動核准規則失敗，但不影響本次執行：$($_.Exception.Message)"
}

if ($enabledAutomaticRules.Count -gt 0) {
    Write-Log "偵測到 $($enabledAutomaticRules.Count) 條已啟用的 WSUS 自動核准規則；已有核准將直接略過，腳本繼續執行"
    foreach ($rule in $enabledAutomaticRules) {
        Write-Log "已啟用規則：$($rule.Name)"
    }
}

Write-LogSection -Title "檢查新更新與下載狀態"

# =========================
# 等待新更新與下載完成閘門
# =========================
$updates = @()

# 先檢查狀態檔記錄的 UpdateId 是否仍存在於當前 SUSDB。
# 即使 ServerId 因還原或複製而沒有變更，仍可自動排除失效狀態。
if ($cycleState.Status -eq "Dispatching") {
    try {
        $stateLookup = Get-UpdatesFromState -Server $wsus -UpdateIds $cycleState.UpdateIds
    }
    catch {
        Write-Log "讀取當月更新清單失敗：$($_.Exception.Message)"
        exit 1
    }

    if ($stateLookup.MissingIds.Count -gt 0) {
        Write-Log "狀態檔有 $($stateLookup.MissingIds.Count) 筆 UpdateId 不存在於當前 SUSDB，判定為 WSUS 重裝後的舊狀態"
        Write-Log "失效 UpdateId：$($stateLookup.MissingIds -join '、')"

        $cycleState = New-CycleState -CycleMonth $cycleMonth -PatchDay $patchDay -WsusServerId $currentWsusServerId
        Save-CycleState -State $cycleState
        Write-Log "已自動清除失效清單，改用當前 WSUS 資料庫重新偵測本月更新"
    }
    else {
        $updates = @($stateLookup.Updates)
    }
}

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
    $clientUpdateCount = (@($newUpdates | Where-Object { Test-UpdateMatchesKeywords -Update $_ -Keywords $ClientProductKeywords })).Count
    $serverUpdateCount = (@($newUpdates | Where-Object { Test-UpdateMatchesKeywords -Update $_ -Keywords $ServerProductKeywords })).Count
    Write-Log "目標更新分類：Windows 11=$clientUpdateCount 筆；Windows Server=$serverUpdateCount 筆"

    try {
        if ($serverConfiguration.HostBinariesOnMicrosoftUpdate) {
            throw "目前設定為由用戶端直接向 Microsoft Update 下載檔案，WSUS 本機沒有內容檔可供本腳本驗證。"
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

if ($updates.Count -eq 0) {
    Write-Log "當月派送清單為空，為避免誤核准，腳本停止"
    exit 1
}

# =========================
# 以實際下載完成日計算 D0～D10
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

$maxDispatchDay = [int](($deptTable | Measure-Object -Property Day -Maximum).Maximum)
$dispatchDay = [Math]::Min($offset, $maxDispatchDay)
Write-Log "目前實際派送週期：D$dispatchDay（D0：$($cycleStartDate.ToString('yyyy-MM-dd'))）"

# =========================
# 正式群組核准流程
# =========================
Write-LogSection -Title "D$dispatchDay 分批核准作業"
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
    $existingApprovalCount = 0
    $matchedUpdateCount = 0

    $deadlineTaipei = $cycleStartDate.AddDays([int]$dept.Day).AddHours([int]$dept.DeadlineHour).AddMinutes([int]$dept.DeadlineMinute)
    $deadlineTaipeiUnspecified = [datetime]::SpecifyKind($deadlineTaipei, [System.DateTimeKind]::Unspecified)
    $deadlineUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($deadlineTaipeiUnspecified, $DeadlineTimeZone)

    if ($dept.Scope -eq "Client") {
        $scopeKeywords = $ClientProductKeywords
        $scopeName = "Windows 11"
    }
    elseif ($dept.Scope -eq "Server") {
        $scopeKeywords = $ServerProductKeywords
        $scopeName = "Windows Server"
    }
    else {
        Write-Log "群組 $($dept.Name) 的 Scope 設定無效：$($dept.Scope)"
        $approvalErrors++
        continue
    }

    foreach ($update in $updates) {
        try {
            [void]$update.Refresh()

            if ($update.IsDeclined -or $update.IsSuperseded) {
                Write-Log "略過已拒絕或已被取代的更新：$($update.Title)"
                continue
            }

            if (!(Test-UpdateMatchesKeywords -Update $update -Keywords $scopeKeywords)) {
                continue
            }

            $matchedUpdateCount++
            $approvalResult = Ensure-InstallApproval -Update $update -Group $group -DeadlineUtc $deadlineUtc

            if ($approvalResult -eq "Created") {
                $newApprovalCount++
                Write-Log "已核准至 $($dept.Name)：$($update.Title)；Deadline(台灣時間)=$($deadlineTaipei.ToString('yyyy-MM-dd HH:mm'))"
            }
            elseif ($approvalResult -eq "AlreadyApproved") {
                $existingApprovalCount++
                Write-Log "已有核准，直接略過：群組=$($dept.Name)；更新=$($update.Title)"
            }
        }
        catch {
            Write-Log "核准失敗：群組=$($dept.Name)；更新=$($update.Title)；錯誤=$($_.Exception.Message)"
            $approvalErrors++
        }
    }

    if ($matchedUpdateCount -eq 0) {
        Write-Log "群組 $($dept.Name) 本月沒有可核准的 $scopeName 目標更新"
    }
    elseif ($newApprovalCount -eq 0) {
        Write-Log "群組 $($dept.Name) 無新增核准，已略過 $existingApprovalCount 筆既有核准"
    }
    else {
        Write-Log "群組 $($dept.Name) 本次新增 $newApprovalCount 筆核准，略過 $existingApprovalCount 筆既有核准"
    }

    Write-Host ""
}

if ($approvalErrors -gt 0) {
    Save-CycleState -State $cycleState
    Write-Log "本次共有 $approvalErrors 筆群組或更新處理錯誤；下次執行會重試"
    exit 1
}

if ($offset -ge $maxDispatchDay) {
    $cycleState.Status = "Completed"
    $cycleState.CompletedDate = $today.ToString("yyyy-MM-dd")
    Save-CycleState -State $cycleState
    Write-Log "本月 D0～D$maxDispatchDay 分批核准作業已全部完成"
}
else {
    Save-CycleState -State $cycleState
    Write-Log "WSUS D$dispatchDay 分批核准作業執行完成"
}

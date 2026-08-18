# WSUS 自動分批核准系統

這是我依實際 WSUS 維運流程設計的 PowerShell 自動化工具。程式會在每月更新完成同步與下載後，把當天記為 D0，再依 D0～D10 的時程逐批核准既有電腦群組，降低一次全面派送更新的風險。

目前版本將 Windows 11 用戶端與 Windows Server 分成兩條派送路線，並為新建立的核准設定台灣時間 Deadline。

> GitHub 公開版本已將正式 WSUS 主機名稱、儲存路徑及組織群組名稱改為範例值；核心流程與防呆邏輯均予以保留。

## 設計目的

一般 WSUS 更新若直接一次核准給所有電腦，發生相容性問題時影響範圍較大。本工具先以測試群組作為 D0，確認後再按日逐步擴大派送範圍，讓更新流程更容易觀察、控管及中止。

## 執行流程

1. 每月 Patch Wednesday（先找第二個星期二，再加一天）後才開始偵測更新。
2. 依 Client 與 Server 各自的產品關鍵字，篩選最新、未拒絕、未被取代的更新。
3. 等待所有目標更新的內容狀態成為 `Ready`。
4. 將實際全部下載完成的日期記錄為 D0。
5. Windows 11 依 D0～D10 分批核准，預設 Deadline 為各派送日台灣時間 12:15。
6. Windows Server 於 D10 核准，預設 Deadline 為台灣時間 17:30。
7. 使用 JSON 狀態檔保存當月進度，讓每日排程能延續同一個派送週期。

## 目前支援的產品範例

- Windows 11
- Microsoft Server operating system-21H2（Windows Server 2022）
- Windows Server 2016
- Windows Server 2019

Office 2016 已從目前版本的自動核准範圍移除。產品關鍵字只負責篩選已同步至 WSUS 的更新；腳本不會修改 WSUS 的「產品與分類」設定。

## 功能與防呆

- 不建立或修改 WSUS 群組結構。
- 目標更新未全部下載完成時，不核准正式群組。
- Client 與 Server 更新只會送至對應 Scope 的群組。
- 新核准使用 `Approve(..., Deadline)` 寫入 Deadline，並以 `Taipei Standard Time` 將台灣時間轉為 WSUS API 使用的 UTC。
- 已有 Install 核准時直接略過，保留原核准與原 Deadline，不取消也不覆寫。
- 可與已啟用的 WSUS 自動核准規則並存；程式只記錄警告，不會因此中止。
- 找不到群組或出現多個同名群組時，會記錄錯誤並跳過。
- 更新已被拒絕或取代時會自動略過。
- 記錄 WSUS `ServerId`；偵測到 WSUS 重裝或更換 SUSDB 時，自動重建週期狀態。
- 即使 `ServerId` 未改變，只要狀態檔中的 UpdateId 已不存在，也會清除失效清單並重新偵測。
- 重新同步後同時限制 ArrivalDate 與 CreationDate，降低把大量歷史更新誤認為本月更新的風險。
- 每月完成最後一個設定日後標記為 `Completed`，避免重複處理。
- `-ResetCycle` 只重設本機狀態，不會撤銷既有 WSUS 核准。

## 使用前需求

- WSUS Server，或已安裝 WSUS Administration API 的 Windows 主機。
- Windows PowerShell 5.1。
- 執行帳號具有 WSUS 更新核准權限。
- WSUS 中已建立對應的 Computer Target Groups。
- WSUS 更新檔儲存在本機；若設定為由用戶端直接向 Microsoft Update 下載，腳本無法驗證 `Ready` 狀態。
- 建議先在測試環境驗證，再放入正式排程。

## 設定方式

開啟 `src/Invoke-WsusStagedApproval.ps1`，修改「基本設定」：

```powershell
$WsusServerName  = "YOUR-WSUS-SERVER"
$UseSsl          = $false
$WsusPort        = 8530
$LogPath         = "C:\ProgramData\WsusStagedApproval\wsus.log"
$StatePath       = "C:\ProgramData\WsusStagedApproval\wsus-cycle-state.json"
$DeadlineTimeZoneId = "Taipei Standard Time"
```

### 選擇要派送的產品

Client 與 Server 使用不同關鍵字，程式會同時搜尋產品名稱與更新標題，且不區分英文大小寫：

```powershell
$ClientProductKeywords = @(
    "Windows 11"
)

$ServerProductKeywords = @(
    "Microsoft Server operating system-21H2",
    "Windows Server 2016",
    "Windows Server 2019"
)
```

### 設定分批群組與 Deadline

修改 `$deptTable`：

- `Name`：必須與 WSUS 既有群組名稱完全一致。
- `Day`：從 D0 起算的派送日。
- `Scope`：只能是 `Client` 或 `Server`。
- `DeadlineHour`、`DeadlineMinute`：台灣時間，採 24 小時制。

```powershell
$deptTable = @(
    @{ Name = "IT-Pilot";          Day = 0;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Headquarters-A";    Day = 1;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Remote-Site";       Day = 9;  Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Client-Fallback";   Day = 10; Scope = "Client"; DeadlineHour = 12; DeadlineMinute = 15 },
    @{ Name = "Server-Production"; Day = 10; Scope = "Server"; DeadlineHour = 17; DeadlineMinute = 30 }
)
```

程式會自動以 `$deptTable` 中最大的 `Day` 作為週期完成日，不需要另外修改 D10 常數。

## WSUS 下載設定說明

腳本不會強制關閉「只有在核准更新後才將更新檔案下載到此伺服器」，也不會因為該選項已啟用而停止。你可以先手動拒絕不相關更新，再依既有的手動或自動規則處理目標更新。

但派送閘門仍要求所有目標更新為 `Ready`。若採用「核准後才下載」，必須先由既有流程讓目標更新完成下載，腳本才會把當天記為 D0。

## 手動執行

以系統管理員身分開啟 PowerShell，切換到專案資料夾後執行：

```powershell
.\src\Invoke-WsusStagedApproval.ps1
```

需要刻意重新開始當月狀態追蹤時：

```powershell
.\src\Invoke-WsusStagedApproval.ps1 -ResetCycle
```

`-ResetCycle` 不會取消已經存在於 WSUS 的核准。

## 建議排程

確認手動執行結果正常後，可在 Windows 工作排程器中設定每天執行一次：

```text
程式：powershell.exe
引數：-NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\src\Invoke-WsusStagedApproval.ps1"
```

實際執行時間可依組織的 WSUS 同步、下載及人工審核流程調整。

## 專案結構

```text
wsus-staged-approval/
├─ src/
│  └─ Invoke-WsusStagedApproval.ps1
├─ .gitignore
├─ LICENSE
└─ README.md
```

## 安全提醒

更新核准會影響受管理的電腦。使用前請仔細確認產品篩選條件、群組名稱、Scope、派送日與 Deadline。請勿將正式主機名稱、內部群組名稱、帳號、憑證、執行記錄或狀態檔提交至公開 GitHub 儲存庫。

## 授權

本專案採用 [MIT License](LICENSE)。

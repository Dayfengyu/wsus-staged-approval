# WSUS 自動分批核准系統

這是我在實際工作環境中，針對 WSUS 更新派送流程所設計的 PowerShell 自動化工具。程式會等待指定更新全部下載完成，再依 D0～D9 的時程逐批核准既有的 WSUS 電腦群組，降低一次全面派送更新的風險。

> GitHub 公開版本已將正式 WSUS 主機名稱、儲存路徑及組織群組名稱改為範例值；核心流程與防呆邏輯均予以保留。

## 設計目的

一般 WSUS 更新若直接一次核准給所有電腦，發生相容性問題時影響範圍較大。本工具先以測試群組作為 D0，確認後再按日逐步擴大派送範圍，讓更新流程更容易觀察與控管。

## 執行流程

1. 每月 Patch Wednesday（美國第二個星期二的隔天）後才開始偵測更新。
2. 依使用者設定的產品關鍵字，篩選最新、未拒絕、未被取代的更新。
3. 沿用現有 WSUS 下載設定，不建立群組，也不進行暫時性的預先核准。
4. 等待所有目標更新的內容狀態都成為 `Ready`。
5. 將實際全部下載完成的日期記錄為 D0。
6. 按照群組設定，依 D0～D9 逐批建立安裝核准。
7. 使用 JSON 狀態檔保存當月進度，讓每日排程能延續同一個派送週期。

## 功能與防呆

- 不建立或修改 WSUS 群組結構。
- 目標更新未全部下載完成時，不核准任何正式群組。
- 避免對同一更新與群組重複建立 Install 核准。
- 找不到群組或出現多個同名群組時，會記錄錯誤並跳過。
- 更新已被拒絕或取代時會自動略過。
- 單次處理失敗時保留狀態，下次排程會重新嘗試。
- 每月完成 D9 後標記為 `Completed`，避免重複處理。
- `-ResetCycle` 只重設本機狀態，不會撤銷既有的 WSUS 核准。

## 使用前需求

- WSUS Server 或已安裝 WSUS Administration API 的 Windows 主機。
- Windows PowerShell 5.1。
- 執行帳號具有 WSUS 更新核准權限。
- WSUS 中已建立對應的 Computer Target Groups。
- 建議先在測試環境驗證，再放入正式排程。

## 設定方式

開啟 `src/Invoke-WsusStagedApproval.ps1`，修改「基本設定」：

```powershell
$WsusServerName = "YOUR-WSUS-SERVER"
$UseSsl         = $false
$WsusPort       = 8530
$LogPath        = "C:\ProgramData\WsusStagedApproval\wsus.log"
$StatePath      = "C:\ProgramData\WsusStagedApproval\wsus-cycle-state.json"
```

### 選擇要派送的產品

在同一個「基本設定」區修改 `$TargetProductKeywords`。程式會同時搜尋 WSUS 的產品名稱與更新標題，而且不區分英文大小寫：

```powershell
$TargetProductKeywords = @(
    "Windows 11",
    "Office 2016",
    "Excel 2016",
    "Word 2016",
    "PowerPoint 2016"
)
```

例如，要加入 Windows 10、Windows Server 2022 與 Microsoft 365 Apps，可改成：

```powershell
$TargetProductKeywords = @(
    "Windows 10",
    "Windows 11",
    "Windows Server 2022",
    "Microsoft 365 Apps"
)
```

每行是一個關鍵字。要加入產品就新增一行，不需要的產品可刪除該行。Office 2016 預設同時列出 Excel、Word 與 PowerPoint，是為了涵蓋標題可能只顯示個別程式名稱的更新。

請注意：這項設定只負責「從已同步到本機 WSUS 的更新中篩選」。使用者仍需先在 WSUS 主控台的產品與分類設定中啟用並同步相關產品；本腳本不會修改 WSUS 的同步產品選項。

### 設定分批群組

接著修改 `$deptTable`。`Name` 必須與 WSUS 既有群組名稱完全一致，`Day` 代表該群組從哪一天開始取得核准：

```powershell
$deptTable = @(
    @{ Name = "IT-Pilot";     Day = 0 },
    @{ Name = "Department-A"; Day = 1 },
    @{ Name = "Branch-01";    Day = 2 },
    @{ Name = "Remote-Site";  Day = 9 }
)
```

## 手動執行

以系統管理員身分開啟 PowerShell，切換到專案資料夾後執行：

```powershell
.\src\Invoke-WsusStagedApproval.ps1
```

需要刻意重新開始當月狀態追蹤時：

```powershell
.\src\Invoke-WsusStagedApproval.ps1 -ResetCycle
```

請注意：`-ResetCycle` 不會取消已經存在於 WSUS 的核准。

## 建議排程

確認手動執行結果正常後，可在 Windows 工作排程器中設定每天執行一次：

```text
程式：powershell.exe
引數：-NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\src\Invoke-WsusStagedApproval.ps1"
```

實際執行時間可依組織的 WSUS 同步及下載排程調整。

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

更新核准會影響受管理的電腦。使用前請仔細確認產品篩選條件、群組名稱與派送日程。請勿將正式主機名稱、內部群組名稱、帳號、憑證、執行記錄或狀態檔提交至公開的 GitHub 儲存庫。

## 授權

本專案採用 [MIT License](LICENSE)。

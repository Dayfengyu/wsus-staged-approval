# WSUS 分批核准自動化

這是一個 PowerShell 自動化工具：等待 WSUS 更新內容下載完成後，再依照既有的 WSUS 電腦目標群組，分批核准安裝更新。

## 功能特色

- 每月 Microsoft Patch Tuesday 的隔天（台灣時間通常為星期三）後，才開始偵測新更新。
- 預設篩選 Windows 11 與 Office 2016 的最新、未被取代更新。
- 不會建立、刪除或變更 WSUS 電腦群組。
- 所有目標更新都處於 `Ready`（下載完成）狀態後，才會核准任何正式群組。
- 使用 JSON 狀態檔記錄當月週期，讓每天重複執行時能安全地延續 D0～D9 分批派送。
- 已存在的安裝核准不會重複建立。

## 使用前條件

- 在 WSUS 伺服器，或已安裝 WSUS Administration API 的 Windows 電腦上執行。
- 執行帳號必須具有 WSUS 更新核准權限。
- 先在 WSUS 建立與 `config/deployment-plan.json` 名稱完全相同的電腦目標群組。
- WSUS 的更新內容下載方式請依組織既有政策設定。

## 設定方式

1. 編輯 `config/deployment-plan.json`。
   - `Name` 必須和既有 WSUS 群組名稱完全相同。
   - `Day` 是派送日，可設為 0 到 9；0 代表第一批。
2. 若環境的產品不同，請調整腳本 `Test-IsTargetUpdate` 函式內的更新篩選條件。
3. 執行時指定 WSUS 主機名稱；若使用 HTTPS，也可指定連接埠與 SSL。

## 執行方式

以系統管理員身分開啟 PowerShell，第一次可先執行：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

再在專案資料夾中執行：

```powershell
.\src\Invoke-WsusStagedApproval.ps1 -WsusServerName 'YOUR-WSUS-SERVER'
```

若 WSUS 使用 HTTPS，加入 `-UseSsl -WsusPort 8531`。

預設的執行紀錄與狀態檔會寫入 `data/` 資料夾；該資料夾已被 `.gitignore` 排除，不會上傳到 GitHub。確認手動執行結果符合預期後，可用 Windows「工作排程器」每天執行相同命令一次。

`-ResetCycle` 只會重設本機的當月狀態追蹤，**不會**撤銷 WSUS 中已做出的核准。僅應在受控測試或確定要重新開始週期時使用。

## 分批派送範例

| 派送日 | 範例群組 |
| --- | --- |
| D0 | IT-Pilot |
| D1 | Headquarters |
| D3 | Branch-East |
| D5 | Branch-West |
| D9 | Remote-Sites |

## 注意事項

請先在測試環境驗證。更新核准會影響受管端點，因此務必檢查產品篩選條件與群組對照。請勿把正式 WSUS 主機名稱、內部群組名稱、執行紀錄、狀態檔、帳密或網路資訊提交至 GitHub。

## 授權

採用 MIT 授權條款，詳見 [LICENSE](LICENSE)。

# WSUS staged approval automation

A PowerShell automation that waits for selected WSUS updates to finish downloading, then approves them gradually to existing WSUS computer target groups.

## What it does

- Starts looking for updates after Patch Wednesday (the day after Microsoft's monthly Patch Tuesday).
- Targets current Windows 11 and Office 2016 updates by default.
- Does not create or alter WSUS computer groups.
- Requires every selected update to be in the `Ready` state before approving any production group.
- Uses a small JSON state file so repeated daily runs continue the same D0–D9 rollout safely.
- Avoids creating duplicate Install approvals.

## Requirements

- Run on a WSUS server, or a Windows host with the WSUS Administration API installed.
- Run under an account permitted to approve updates in WSUS.
- Create the WSUS computer target groups named in `config/deployment-plan.json` before running the script.
- Configure WSUS content download according to your own operational policy.

## Configure

1. Edit `config/deployment-plan.json`. `Name` must exactly match an existing WSUS group; `Day` is the rollout day, from 0 to 9.
2. Change the target-product matching logic in `Test-IsTargetUpdate` if your environment uses different products.
3. Set your WSUS host name and, if necessary, port or SSL options when running the command.

## Run

Open an elevated PowerShell session and run:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\src\Invoke-WsusStagedApproval.ps1 -WsusServerName 'YOUR-WSUS-SERVER'
```

For HTTPS WSUS, add `-UseSsl -WsusPort 8531`.

The default log and state files are written beneath `data/`, which is excluded from Git. Schedule the same command to run once per day with Windows Task Scheduler after validating it manually.

`-ResetCycle` resets only the local state tracker for the current month. It **does not** revoke approvals already made in WSUS; use it only for controlled testing or a deliberate restart.

## Rollout timeline

| Day | Example group |
| --- | --- |
| D0 | IT-Pilot |
| D1 | Headquarters |
| D3 | Branch-East |
| D5 | Branch-West |
| D9 | Remote-Sites |

## Safety notes

Test in a non-production WSUS environment first. Review the product filter and group mapping carefully: approving updates affects managed endpoints. Do not commit server names, internal group names, logs, state files, credentials, or network details.

## License

MIT. See [LICENSE](LICENSE).

# Repo Contents And Responsibilities

This repository should contain only portable installer/runtime assets.

## Include

- `analysis.sh`
  - The current production audit script.
  - Copied from the verified `analysis_4.1.sh`.

- `install.sh`
  - Interactive installer.
  - Prompts for s-ui log path, Telegram Bot Token, Chat ID, node name, s-ui service name.
  - Generates local `.install.conf`.
  - Generates local `telegram.conf`.
  - Generates and installs systemd services/timers.

- `update.sh`
  - Curl-based support script updater.
  - Downloads installer, runner, test script, template, bootstrap, and version file.
  - Re-runs `install.sh --non-interactive` if support scripts changed.

- `run.sh`
  - Runtime task entrypoint.
  - Refreshes `analysis.sh` atomically before running daily, weekly, or cleanup tasks.
  - Falls back to the local `analysis.sh` when the remote refresh fails.

- `bootstrap.sh`
  - Entry point for `bash <(curl -Ls URL)`.
  - Downloads runtime files into `/opt/sui-audit` or `$SUI_AUDIT_DIR`, then runs `install.sh`.

- `test_telegram.sh`
  - Sends a simple Telegram test message from local `telegram.conf`.

- `telegram.conf.example`
  - Safe template only.
  - No real token or chat id.

- `README.md`
  - Install/update/deploy instructions.

- `.gitignore`
  - Prevents secrets, logs, reports, and archives from entering git.

## Exclude

- `telegram.conf`
- `.install.conf`
- `s-ui.log`
- `archives/`
- `state/`
- `warnings/`
- generated `systemd/`
- real reports
- `.DS_Store`

## Install Flow

1. User runs `bash <(curl -Ls RAW_BOOTSTRAP_URL)`.
2. `bootstrap.sh` downloads runtime files to `/opt/sui-audit` or `$SUI_AUDIT_DIR`.
3. `install.sh` prompts for log path and Telegram values, then writes `.install.conf` and `telegram.conf`.
4. `install.sh` installs systemd timers:
   - `sui-audit-update.timer`: daily 01:50
   - `sui-audit-daily.timer`: daily 02:10
   - `sui-audit-weekly-summary.timer`: Monday 02:20
   - `sui-audit-cleanup.timer`: monthly day 1 02:30

## Update Flow

1. `sui-audit-update.timer` runs `update.sh`.
2. `update.sh` downloads support scripts from the raw GitHub URL.
3. If support scripts changed, it runs `install.sh --non-interactive`.
4. Each `run.sh` invocation refreshes `analysis.sh` before executing the requested task.
5. Local `.install.conf`, `telegram.conf`, `users.list`, archives, and logs are preserved.

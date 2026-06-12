# s-ui Audit

Daily s-ui / sing-box log audit with local-time slicing, Telegram summaries, archive retention, weekly summaries, and monthly cleanup.

## One-Line Install

```bash
cd /path/to/your/s-ui-runtime
bash <(curl -Ls https://raw.githubusercontent.com/EliotHang/sui-audit/main/bootstrap.sh)
```

Optional custom install directory:

```bash
SUI_AUDIT_DIR="/opt/sui-audit" bash <(curl -Ls https://raw.githubusercontent.com/EliotHang/sui-audit/main/bootstrap.sh)
```

## What Gets Installed

- `analysis.sh`: audit script
- `install.sh`: interactive installer for log path, Telegram config, and systemd timers
- `run.sh`: task runner; refreshes `analysis.sh` before each audit task
- `update.sh`: curl-based updater for support scripts
- `uninstall.sh`: removes systemd timers/services and optionally purges local audit files
- `test_telegram.sh`: simple Telegram test sender
- `telegram.conf.example`: config template

Runtime files are intentionally ignored:

- `telegram.conf`
- `.install.conf`
- `s-ui.log`
- `archives/`
- `state/`
- `warnings/`
- `users.list`

`analysis.sh` creates `users.list` automatically when it is missing. The initial file contains every user found in the current log, so later you can edit it to keep only the users you want daily audits to include.

## Schedule

- Update check: local VPS time `01:50`
- Daily audit: local VPS time `02:10`
- Weekly Telegram summary: Monday `02:20`
- Monthly cleanup: day 1 `02:30`

By default, `bootstrap.sh` installs into the directory where you run the command. Run it from your s-ui runtime directory if `s-ui.log` is there. During installation, enter the real s-ui log path when prompted; the default is `s-ui.log` relative to that directory.

## Manual Commands

```bash
./run.sh --daily
./run.sh --date 2026-05-16
./run.sh --weekly-summary
./run.sh --cleanup-dry-run
./test_telegram.sh
./update.sh
./uninstall.sh
./uninstall.sh --purge
```

## Update

`run.sh` refreshes `analysis.sh` from GitHub before each audit task. If the network is temporarily unavailable, it falls back to the existing local `analysis.sh`.

To refresh support scripts manually, run:

```bash
./update.sh
```

It downloads `install.sh`, `run.sh`, `test_telegram.sh`, `uninstall.sh`, `telegram.conf.example`, `bootstrap.sh`, and `VERSION` from the raw GitHub URL, preserves local `telegram.conf` and `.install.conf`, and reinstalls systemd timers when support scripts changed.

The installer also creates `sui-audit-update.timer`, which runs before the daily audit and refreshes support scripts automatically.

## Uninstall

Remove timers/services only:

```bash
./uninstall.sh
```

Remove timers/services plus local audit scripts, configs, archives, state, warnings, and generated reports:

```bash
./uninstall.sh --purge
```

`s-ui.log` is never deleted by the uninstaller.

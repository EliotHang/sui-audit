# Agent Maintenance Guide

This repository is a personal deployment package for `s-ui` / `sing-box` log auditing. Keep changes small, portable, and friendly to unattended systemd runs.

## Tool Responsibilities

- `analysis.sh`
  - Main audit engine.
  - Parses `s-ui.log`, slices local-day windows, detects risky user behavior, writes Markdown reports, archives daily outputs, sends Telegram summaries, creates warning-window logs, builds weekly summaries, and performs retention cleanup.
  - Requires Bash 4+, GNU `grep -P`, GNU `date -d`, `awk`, `sed`, `sort`, `find`, and `flock` for automated modes.

- `install.sh`
  - Interactive installer and systemd unit generator.
  - Creates `.install.conf` and `telegram.conf` when missing.
  - Installs or refreshes update, daily, weekly-summary, and cleanup timers.
  - Daily audit must run with `-u users.list`; first analysis creates `users.list` if it is missing.

- `run.sh`
  - Runtime entrypoint for systemd and manual tasks.
  - Refreshes `analysis.sh` from the configured raw URL before execution.
  - Falls back to the local `analysis.sh` if remote refresh fails.

- `update.sh`
  - Updates support files from the configured raw URL.
  - Preserves local runtime files such as `.install.conf`, `telegram.conf`, `users.list`, logs, archives, state, and reports.
  - Re-runs `install.sh --non-interactive` when support scripts change so systemd units stay current.

- `bootstrap.sh`
  - One-line install entrypoint for `bash <(curl -Ls URL)`.
  - Downloads release files into the current directory or `$SUI_AUDIT_DIR`, then starts `install.sh`.

- `uninstall.sh`
  - Removes systemd units by default.
  - `--purge` removes this tool's local files and generated audit data.
  - Must never delete `s-ui.log`.

- `test_telegram.sh`
  - Sends a simple Telegram test message using local `telegram.conf`.

- `telegram.conf.example`
  - Safe template only. Never commit real tokens or chat IDs.

## Behavioral Requirements

- Treat log timestamps as the log's local time. Do not add UTC conversion or timezone shifting for window slicing.
- Keep archive depth shallow:
  - reports: `archives/reports/YYYYMM/sui-audit-YYYY-MM-DD.md`
  - logs: `archives/logs/YYYYMM/s-ui-YYYY-MM-DD.log.gz`
  - warnings: `archives/warnings/YYYYMM/YYYY-MM-DD/`
- `users.list` is a managed runtime file:
  - It is ignored by git.
  - If missing, `analysis.sh` creates it with all users discovered from the available source log.
  - Existing `users.list` must be preserved and used as the daily filter.
  - `--all-users` may bypass filtering for one run, but should still leave a default list available.
- Client IP counting must preserve frequency distribution:
  - In `connection-id` mode, count all matched connections.
  - Only use random sampling for the `neighbor-window` fallback mode.
  - Fallback sample size defaults to 400.
  - Do not deduplicate sampled fallback connections before counting IPs.
- Runtime secrets and generated data must stay out of git:
  - `telegram.conf`
  - `.install.conf`
  - `users.list`
  - `s-ui.log`
  - `archives/`
  - `state/`
  - `warnings/`
  - generated `systemd/`
  - generated reports

## Maintenance Rules

- Prefer Bash and standard GNU utilities already used by the project. Do not introduce new runtime dependencies unless clearly necessary.
- Keep scripts compatible with Debian 12-style servers.
- Preserve offline/fallback behavior: failed remote refresh should not break existing local audits when a usable local script exists.
- When changing install or update behavior, check both fresh install and already-deployed auto-update flows.
- When changing path layouts, update all related code paths: report hints, archiving, weekly summary lookup, cleanup, README, and this guide.
- When changing `analysis.sh`, remember that deployed hosts may refresh it before each run through `run.sh`.
- When changing support scripts, remember that deployed hosts may refresh them through `update.sh`, which can trigger `install.sh --non-interactive`.

## Validation Checklist

Run these before committing:

```bash
bash -n analysis.sh install.sh run.sh update.sh bootstrap.sh uninstall.sh test_telegram.sh
git diff --check
git status --short --branch
```

If Bash 4+ is available, also run a small real audit against a sample log with temporary archive/state paths. On macOS, the system Bash is often too old for `analysis.sh`; syntax checks can still run, but full execution should be verified on a Bash 4+ / GNU userland environment.

## Release Notes

- Commit only source files and safe templates.
- Do not commit local runtime configs, logs, or generated reports.
- After pushing to `origin/main`, existing deployments should update automatically:
  - `run.sh` refreshes `analysis.sh` before audit tasks.
  - `sui-audit-update.timer` runs `update.sh`, which refreshes support scripts and reinstalls timers when needed.

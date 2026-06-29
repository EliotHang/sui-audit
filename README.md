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

## v0 Master / Worker Preview

Version `v0.0.0` starts the Rust-based master/worker control plane while keeping the Bash audit engine in place. `v1` is reserved for the first formal stable release.

- `sui-audit-master`: talks to Telegram, stores jobs, and exposes worker polling APIs.
- `sui-audit-worker`: polls the master over HTTPS, runs local audit commands, and reports results back.
- Workers should not talk to Telegram directly in the new mode; the master sends Telegram messages.

Recommended network shape:

```text
Telegram <-> sui-audit-master <-> sui-audit-worker -> run.sh / analysis.sh
```

The default master URL is `https://audit.990829.xyz`. Put Caddy or Nginx in front of the master process:

```text
Caddy/Nginx :443 -> sui-audit-master 127.0.0.1:8787
```

The GitHub repository can contain Rust source under `src/`, but production hosts do not need the source tree or Rust toolchain. Build a release package locally or in CI:

```bash
cargo build --release --bins
./package_release.sh
```

The package contains only the master/worker binaries, install scripts, config examples, and `VERSION`.

For Linux servers, prefer GitHub Actions release builds instead of compiling on macOS. Push a tag to build and publish a Linux amd64 package:

```bash
git tag v0.0.0
git push origin v0.0.0
```

The release asset will be named like:

```text
sui-audit-0.0.0-linux-amd64.tar.gz
```

Use `uname -m` on the server. `x86_64` servers should use the `linux-amd64` package.

Install the master directly from the GitHub Release on a Debian/Ubuntu VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EliotHang/sui-audit/main/bootstrap_master.sh)
```

For this development branch before it is merged to `main`, use:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EliotHang/sui-audit/feature/master-worker-5.0/bootstrap_master.sh)
```

Install a worker directly from the GitHub Release on a Debian/Ubuntu VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EliotHang/sui-audit/feature/master-worker-5.0/bootstrap_worker.sh)
```

The worker installer automatically generates a UUID-style worker id and uses `https://audit.990829.xyz` as the default master URL. Copy the Worker Token from the master install and paste it into the worker installer.

Master install flow:

```bash
tar -xzf sui-audit-<version>.tar.gz
cd sui-audit-<version>
sudo ./install_master.sh
sudo install -m 0600 master.toml.example /opt/sui-audit-master/master.toml
sudo nano /opt/sui-audit-master/master.toml
sudo nano /opt/sui-audit-master/master.env
sudo systemctl restart sui-audit-master
```

Worker install flow:

```bash
tar -xzf sui-audit-<version>.tar.gz
cd sui-audit-<version>
sudo ./install_worker.sh
sudo nano /opt/sui-audit-worker/worker.toml
sudo nano /opt/sui-audit-worker/worker.env
sudo systemctl restart sui-audit-worker
```

Keep secrets out of git. Put Telegram bot tokens and worker tokens in `master.env` / `worker.env`, not in committed config files.

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

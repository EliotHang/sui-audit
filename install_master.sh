#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SUI_AUDIT_MASTER_DIR:-/opt/sui-audit-master}"
SERVICE_NAME="${SUI_AUDIT_MASTER_SERVICE:-sui-audit-master}"

log_info() {
    printf '[INFO] %s\n' "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        require_cmd sudo
        sudo "$@"
    fi
}

write_root_file() {
    local target="$1"
    local tmp_file

    tmp_file="$(mktemp -t sui_audit_master_unit_XXXXXX)"
    cat > "$tmp_file"
    if (( EUID == 0 )); then
        install -m 0644 "$tmp_file" "$target"
    else
        require_cmd sudo
        sudo install -m 0644 "$tmp_file" "$target"
    fi
    rm -f "$tmp_file"
}

main() {
    require_cmd install
    require_cmd systemctl

    local binary_source=""
    if [[ -x "$SCRIPT_DIR/sui-audit-master" ]]; then
        binary_source="$SCRIPT_DIR/sui-audit-master"
    elif [[ -x "$SCRIPT_DIR/target/release/sui-audit-master" ]]; then
        binary_source="$SCRIPT_DIR/target/release/sui-audit-master"
    else
        die "找不到 sui-audit-master 二进制；请使用 release 包，或先运行 cargo build --release --bin sui-audit-master"
    fi

    as_root install -d -m 0755 "$INSTALL_DIR"
    as_root install -m 0755 "$binary_source" "$INSTALL_DIR/sui-audit-master"

    if [[ ! -f "$INSTALL_DIR/master.toml" ]]; then
        as_root install -m 0600 "$SCRIPT_DIR/master.toml.example" "$INSTALL_DIR/master.toml"
        log_info "已创建配置: $INSTALL_DIR/master.toml"
    fi

    write_root_file "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=s-ui Audit Master
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${INSTALL_DIR}/master.env
ExecStart=${INSTALL_DIR}/sui-audit-master --config ${INSTALL_DIR}/master.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    if [[ ! -f "$INSTALL_DIR/master.env" ]]; then
        write_root_file "$INSTALL_DIR/master.env" << EOF
SUI_AUDIT_TELEGRAM_BOT_TOKEN=
SUI_AUDIT_WORKER_TOKEN=
EOF
        as_root chmod 0600 "$INSTALL_DIR/master.env"
        log_info "已创建密钥文件: $INSTALL_DIR/master.env"
    fi

    as_root systemctl daemon-reload
    as_root systemctl enable "$SERVICE_NAME"
    log_info "安装完成。请编辑 $INSTALL_DIR/master.toml 和 $INSTALL_DIR/master.env 后运行: systemctl restart $SERVICE_NAME"
}

main "$@"

#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNITS=(
    "sui-audit-update"
    "sui-audit-daily"
    "sui-audit-weekly-summary"
    "sui-audit-cleanup"
)

LOCAL_FILES=(
    "analysis.sh"
    "bootstrap.sh"
    "install.sh"
    "run.sh"
    "update.sh"
    "uninstall.sh"
    "test_telegram.sh"
    "telegram.conf.example"
    "VERSION"
    ".install.conf"
    "telegram.conf"
)

LOCAL_DIRS=(
    "archives"
    "state"
    "warnings"
    "systemd"
)

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

systemctl_as_root() {
    if (( EUID == 0 )); then
        systemctl "$@"
    else
        sudo systemctl "$@"
    fi
}

rm_as_root() {
    if (( EUID == 0 )); then
        rm -rf "$@"
    else
        sudo rm -rf "$@"
    fi
}

confirm() {
    local prompt="$1"
    local answer

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        return 0
    fi

    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

remove_systemd_units() {
    local name

    for name in "${UNITS[@]}"; do
        systemctl_as_root disable --now "$name.timer" >/dev/null 2>&1 || true
        systemctl_as_root stop "$name.service" >/dev/null 2>&1 || true
    done

    for name in "${UNITS[@]}"; do
        rm_as_root "/etc/systemd/system/$name.timer" "/etc/systemd/system/$name.service"
    done

    systemctl_as_root daemon-reload
    systemctl_as_root reset-failed >/dev/null 2>&1 || true
    log_info "已移除 sui-audit systemd timers/services"
}

remove_local_files() {
    local item

    cd "$SCRIPT_DIR"

    for item in "${LOCAL_FILES[@]}"; do
        [[ -e "$SCRIPT_DIR/$item" ]] && rm -f "$SCRIPT_DIR/$item"
    done

    for item in "${LOCAL_DIRS[@]}"; do
        [[ -e "$SCRIPT_DIR/$item" ]] && rm -rf "$SCRIPT_DIR/$item"
    done

    find "$SCRIPT_DIR" -maxdepth 1 -type f \( \
        -name 'sui-audit-*.md' -o \
        -name 'sui-滥用检测详细报告-*.md' -o \
        -name '*.tmp' \
    \) -delete

    log_info "已清理本工具文件与归档数据"
    log_warn "未删除 s-ui.log；这是 s-ui 原始日志，不属于本工具安装内容"
}

usage() {
    cat <<'EOF_USAGE'
用法: ./uninstall.sh [--purge] [--yes]

默认只停用并删除 systemd timer/service。

选项:
  --purge    同时删除本目录下的 sui-audit 脚本、配置、归档、状态和报告
  --yes      跳过确认
  -h,--help  显示帮助

注意:
  --purge 不会删除 s-ui.log。
EOF_USAGE
}

main() {
    PURGE=0
    ASSUME_YES=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge)
                PURGE=1
                shift
                ;;
            --yes|-y)
                ASSUME_YES=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
    done

    require_cmd systemctl
    if (( EUID != 0 )); then
        require_cmd sudo
    fi

    log_info "安装目录: $SCRIPT_DIR"
    remove_systemd_units

    if [[ "$PURGE" -eq 1 ]]; then
        if confirm "确认删除本工具脚本、配置、归档、状态和报告？"; then
            remove_local_files
        else
            log_warn "已跳过本地文件清理"
        fi
    else
        log_info "本地文件已保留。如需全部清理，运行: $SCRIPT_DIR/uninstall.sh --purge"
    fi
}

main "$@"

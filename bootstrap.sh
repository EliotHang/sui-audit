#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

DEFAULT_BASE_URL="https://raw.githubusercontent.com/EliotHang/sui-audit/main"
BASE_URL="${SUI_AUDIT_BASE_URL:-$DEFAULT_BASE_URL}"
INSTALL_DIR="${SUI_AUDIT_DIR:-/opt/sui-audit}"

FILES=(
    "analysis.sh"
    "install.sh"
    "run.sh"
    "update.sh"
    "test_telegram.sh"
    "telegram.conf.example"
    "VERSION"
)

log_info() {
    printf '[INFO] %s\n' "$*"
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

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

download_file() {
    local name="$1"
    local url="$BASE_URL/$name"
    local target="$INSTALL_DIR/$name"
    local tmp="$target.tmp.$$"

    log_info "下载 $name"
    as_root curl -fsSL "$url" -o "$tmp"

    case "$name" in
        *.sh)
            as_root bash -n "$tmp"
            as_root chmod 0755 "$tmp"
            ;;
        *)
            as_root chmod 0644 "$tmp"
            ;;
    esac

    as_root mv "$tmp" "$target"
}

main() {
    require_cmd bash
    require_cmd curl
    if (( EUID != 0 )); then
        require_cmd sudo
    fi

    log_info "远程地址: $BASE_URL"
    log_info "安装目录: $INSTALL_DIR"

    as_root mkdir -p "$INSTALL_DIR"

    local file
    for file in "${FILES[@]}"; do
        download_file "$file"
    done

    log_info "执行安装器"
    as_root bash "$INSTALL_DIR/install.sh"
}

main "$@"

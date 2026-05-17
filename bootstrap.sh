#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

DEFAULT_BASE_URL="https://raw.githubusercontent.com/EliotHang/sui-audit/main"
BASE_URL="${SUI_AUDIT_BASE_URL:-$DEFAULT_BASE_URL}"
INSTALL_DIR="${SUI_AUDIT_DIR:-$PWD}"

FILES=(
    "analysis.sh"
    "install.sh"
    "run.sh"
    "update.sh"
    "uninstall.sh"
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

download_file() {
    local name="$1"
    local url="$BASE_URL/$name"
    local target="$INSTALL_DIR/$name"
    local tmp="$target.tmp.$$"

    log_info "下载 $name"
    curl -fsSL "$url" -o "$tmp"

    case "$name" in
        *.sh)
            bash -n "$tmp"
            chmod 0755 "$tmp"
            ;;
        *)
            chmod 0644 "$tmp"
            ;;
    esac

    mv "$tmp" "$target"
}

main() {
    require_cmd bash
    require_cmd curl

    log_info "远程地址: $BASE_URL"
    log_info "安装目录: $INSTALL_DIR"

    mkdir -p "$INSTALL_DIR"
    [[ -w "$INSTALL_DIR" ]] || die "安装目录不可写，请切换到可写目录，或设置 SUI_AUDIT_DIR"

    local file
    for file in "${FILES[@]}"; do
        download_file "$file"
    done

    log_info "执行安装器"
    as_root bash "$INSTALL_DIR/install.sh"
}

main "$@"

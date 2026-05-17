#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_CONF="$SCRIPT_DIR/.install.conf"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/EliotHang/sui-audit/main"

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

refresh_analysis() {
    local url="$SUI_AUDIT_ANALYSIS_URL"
    local target="$SCRIPT_DIR/analysis.sh"
    local tmp="$target.tmp.$$"

    log_info "刷新 analysis.sh: $url"
    if curl -fsSL "$url" -o "$tmp" && bash -n "$tmp"; then
        chmod 0755 "$tmp"
        mv "$tmp" "$target"
        log_info "analysis.sh 已更新"
        return 0
    fi

    rm -f "$tmp"
    if [[ -x "$target" ]]; then
        log_warn "远程 analysis.sh 刷新失败，继续使用本地版本"
        return 0
    fi

    die "远程 analysis.sh 刷新失败，且本地没有可用版本"
}

main() {
    require_cmd curl
    require_cmd bash

    cd "$SCRIPT_DIR"

    if [[ -f "$INSTALL_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_CONF"
    fi

    SUI_AUDIT_BASE_URL="${SUI_AUDIT_BASE_URL:-$DEFAULT_BASE_URL}"
    SUI_AUDIT_ANALYSIS_URL="${SUI_AUDIT_ANALYSIS_URL:-$SUI_AUDIT_BASE_URL/analysis.sh}"

    refresh_analysis

    exec "$SCRIPT_DIR/analysis.sh" "$@"
}

main "$@"

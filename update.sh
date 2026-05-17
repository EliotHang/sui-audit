#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_CONF="$SCRIPT_DIR/.install.conf"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/EliotHang/sui-audit/main"

SUPPORT_FILES=(
    "install.sh"
    "run.sh"
    "test_telegram.sh"
    "telegram.conf.example"
    "bootstrap.sh"
    "VERSION"
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

download_if_changed() {
    local name="$1"
    local url="$SUI_AUDIT_BASE_URL/$name"
    local target="$SCRIPT_DIR/$name"
    local tmp="$target.tmp.$$"

    log_info "检查 $name"
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

    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        log_info "$name 已是最新"
        return 1
    fi

    mv "$tmp" "$target"
    log_info "$name 已更新"
    return 0
}

main() {
    require_cmd curl
    require_cmd cmp

    cd "$SCRIPT_DIR"

    if [[ -f "$INSTALL_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$INSTALL_CONF"
    fi
    SUI_AUDIT_BASE_URL="${SUI_AUDIT_BASE_URL:-$DEFAULT_BASE_URL}"

    local changed=0
    local file
    for file in "${SUPPORT_FILES[@]}"; do
        if download_if_changed "$file"; then
            changed=1
        fi
    done

    if [[ "$changed" -eq 1 ]]; then
        log_info "支撑脚本发生变化，重新安装 systemd timer"
        bash "$SCRIPT_DIR/install.sh" --non-interactive
    else
        log_info "支撑脚本无需更新"
    fi
}

main "$@"

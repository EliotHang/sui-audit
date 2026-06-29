#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

GITHUB_REPO="${SUI_AUDIT_GITHUB_REPO:-EliotHang/sui-audit}"
RELEASE_VERSION="${SUI_AUDIT_RELEASE_VERSION:-0.0.0}"
INSTALL_DIR="${SUI_AUDIT_WORKER_DIR:-/opt/sui-audit-worker}"
TMP_DIR=""

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

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

detect_asset_suffix() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            printf 'linux-amd64'
            ;;
        *)
            die "暂不支持当前架构: $machine；当前 release 只提供 linux-amd64"
            ;;
    esac
}

main() {
    require_cmd curl
    require_cmd tar
    require_cmd uname
    require_cmd bash

    local suffix
    local archive_name
    local url

    suffix="$(detect_asset_suffix)"
    archive_name="sui-audit-${RELEASE_VERSION}-${suffix}.tar.gz"
    url="https://github.com/${GITHUB_REPO}/releases/download/v${RELEASE_VERSION}/${archive_name}"

    TMP_DIR="$(mktemp -d -t sui_audit_worker_bootstrap_XXXXXX)"
    trap cleanup EXIT

    log_info "GitHub repo: ${GITHUB_REPO}"
    log_info "Release: v${RELEASE_VERSION}"
    log_info "下载: ${url}"
    curl -fsSL "$url" -o "$TMP_DIR/$archive_name"

    log_info "解压 release 包"
    tar -xzf "$TMP_DIR/$archive_name" -C "$TMP_DIR"

    local package_dir="$TMP_DIR/sui-audit-${RELEASE_VERSION}-${suffix}"
    [[ -d "$package_dir" ]] || die "release 包结构异常，找不到目录: $package_dir"

    log_info "安装 worker 到: ${INSTALL_DIR}"
    SUI_AUDIT_WORKER_DIR="$INSTALL_DIR" bash "$package_dir/install_worker.sh" "$@"

    log_info "安装完成"
}

main "$@"

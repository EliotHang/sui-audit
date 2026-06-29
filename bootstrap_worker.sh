#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

GITHUB_REPO="${SUI_AUDIT_GITHUB_REPO:-EliotHang/sui-audit}"
RELEASE_VERSION="${SUI_AUDIT_RELEASE_VERSION:-0.0.0}"
INSTALL_DIR="${SUI_AUDIT_WORKER_DIR:-/opt/sui-audit-worker}"
TMP_DIR=""
UPDATE_MODE=0

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

usage() {
    cat << EOF
用法: $0 [--update] [install_worker.sh 参数]

环境变量:
  SUI_AUDIT_GITHUB_REPO      默认: EliotHang/sui-audit
  SUI_AUDIT_RELEASE_VERSION  默认: 0.0.0
  SUI_AUDIT_WORKER_DIR       默认: /opt/sui-audit-worker

示例:
  $0
  $0 --update
  SUI_AUDIT_RELEASE_VERSION=0.0.1 $0 --update
EOF
}

parse_bootstrap_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update)
                UPDATE_MODE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done
    INSTALL_ARGS=("$@")
}

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        require_cmd sudo
        sudo "$@"
    fi
}

update_worker() {
    local package_dir="$1"

    [[ -x "$package_dir/sui-audit-worker" ]] || die "release 包缺少 sui-audit-worker"
    as_root install -d -m 0755 "$INSTALL_DIR"
    as_root install -m 0755 "$package_dir/sui-audit-worker" "$INSTALL_DIR/sui-audit-worker"
    as_root systemctl daemon-reload
    as_root systemctl restart sui-audit-worker
    log_info "worker 已更新并重启: sui-audit-worker"
}

main() {
    parse_bootstrap_args "$@"
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

    if [[ "$UPDATE_MODE" -eq 1 ]]; then
        log_info "更新 worker: ${INSTALL_DIR}"
        update_worker "$package_dir"
    else
        log_info "安装 worker 到: ${INSTALL_DIR}"
        SUI_AUDIT_WORKER_DIR="$INSTALL_DIR" bash "$package_dir/install_worker.sh" "${INSTALL_ARGS[@]}"
    fi

    log_info "完成"
}

main "$@"

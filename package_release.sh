#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${SUI_AUDIT_RELEASE_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(awk -F '"' '/^version = / {print $2; exit}' "$SCRIPT_DIR/Cargo.toml")"
fi
TARGET_SUFFIX="${SUI_AUDIT_PACKAGE_SUFFIX:-local}"
PACKAGE_NAME="sui-audit-${VERSION}-${TARGET_SUFFIX}"
DIST_DIR="$SCRIPT_DIR/dist/$PACKAGE_NAME"
ARCHIVE="$SCRIPT_DIR/dist/$PACKAGE_NAME.tar.gz"

log_info() {
    printf '[INFO] %s\n' "$*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '[ERROR] 缺少依赖命令: %s\n' "$1" >&2
        exit 1
    }
}

main() {
    require_cmd cargo
    require_cmd tar

    cd "$SCRIPT_DIR"
    cargo build --release --bins

    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    install -m 0755 target/release/sui-audit-master "$DIST_DIR/sui-audit-master"
    install -m 0755 target/release/sui-audit-worker "$DIST_DIR/sui-audit-worker"
    install -m 0755 install_master.sh "$DIST_DIR/install_master.sh"
    install -m 0755 install_worker.sh "$DIST_DIR/install_worker.sh"
    install -m 0755 bootstrap_master.sh "$DIST_DIR/bootstrap_master.sh"
    install -m 0755 bootstrap_worker.sh "$DIST_DIR/bootstrap_worker.sh"
    install -m 0644 master.toml.example "$DIST_DIR/master.toml.example"
    install -m 0644 worker.toml.example "$DIST_DIR/worker.toml.example"
    install -m 0644 VERSION "$DIST_DIR/VERSION"

    tar -C "$SCRIPT_DIR/dist" -czf "$ARCHIVE" "$PACKAGE_NAME"
    log_info "release package: $ARCHIVE"
}

main "$@"

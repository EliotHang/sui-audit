#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SUI_AUDIT_WORKER_DIR:-/opt/sui-audit-worker}"
SERVICE_NAME="${SUI_AUDIT_WORKER_SERVICE:-sui-audit-worker}"
NON_INTERACTIVE=0

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

ask() {
    local prompt="$1"
    local default_value="${2:-}"
    local answer

    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " answer
        printf '%s' "${answer:-$default_value}"
    else
        read -r -p "$prompt: " answer
        printf '%s' "$answer"
    fi
}

ask_secret() {
    local prompt="$1"
    local answer

    read -r -s -p "$prompt: " answer
    printf '\n' >&2
    printf '%s' "$answer"
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

    tmp_file="$(mktemp -t sui_audit_worker_file_XXXXXX)"
    cat > "$tmp_file"
    if (( EUID == 0 )); then
        install -m 0644 "$tmp_file" "$target"
    else
        require_cmd sudo
        sudo install -m 0644 "$tmp_file" "$target"
    fi
    rm -f "$tmp_file"
}

generate_uuid() {
    local hex

    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid
        return 0
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        hex="$(openssl rand -hex 16)"
    else
        hex="$(date '+%s%N' | sha256sum | awk '{print substr($1, 1, 32)}')"
    fi
    printf '%s-%s-%s-%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

toml_string_array() {
    local raw="${1:-}"
    local first=1
    local item
    local escaped

    raw="${raw//,/ }"
    for item in $raw; do
        [[ -n "$item" ]] || continue
        escaped="${item//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        if [[ "$first" -eq 0 ]]; then
            printf ', '
        fi
        printf '"%s"' "$escaped"
        first=0
    done
}

write_worker_toml() {
    local target="$1"
    local worker_id
    local worker_name
    local tags
    local master_url
    local poll_interval
    local audit_repo_dir
    local audit_run_script

    if [[ -f "$target" ]]; then
        log_info "已存在配置，不覆盖: $target"
        return 0
    fi

    worker_id="$(generate_uuid)"
    worker_name="${SUI_AUDIT_WORKER_NAME:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'worker')}"
    tags="${SUI_AUDIT_WORKER_TAGS:-s-ui,prod}"
    master_url="${SUI_AUDIT_MASTER_URL:-https://audit.990829.xyz}"
    poll_interval="${SUI_AUDIT_WORKER_POLL_INTERVAL:-15}"
    audit_repo_dir="${SUI_AUDIT_REPO_DIR:-/opt/sui-audit}"
    audit_run_script="${SUI_AUDIT_RUN_SCRIPT:-$audit_repo_dir/run.sh}"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        printf '\n[Worker 配置]\n'
        printf 'Worker ID 将自动生成，不需要手动指定。\n'
        printf 'Worker ID: %s\n\n' "$worker_id"
        worker_name="$(ask 'Worker name' "$worker_name")"
        tags="$(ask 'Worker tags，逗号分隔' "$tags")"
        master_url="$(ask 'Master URL' "$master_url")"
        poll_interval="$(ask 'Poll interval seconds' "$poll_interval")"

        printf '\n[审计脚本]\n'
        printf '这里指向现有 Bash 审计安装目录。worker 会调用 run.sh，不会直接实现审计逻辑。\n\n'
        audit_repo_dir="$(ask 'sui-audit repo dir' "$audit_repo_dir")"
        audit_run_script="$(ask 'run.sh path' "$audit_repo_dir/run.sh")"
    fi

    write_root_file "$target" << EOF
[worker]
id = "${worker_id}"
name = "${worker_name}"
tags = [$(toml_string_array "$tags")]

[master]
url = "${master_url}"
token_env = "SUI_AUDIT_WORKER_TOKEN"
poll_interval_seconds = ${poll_interval}

[audit]
repo_dir = "${audit_repo_dir}"
run_script = "${audit_run_script}"

[telegram]
send_direct = false
EOF
    as_root chmod 0600 "$target"
    log_info "已创建配置: $target"
    log_info "Worker ID: $worker_id"

    if [[ ! -x "$audit_run_script" ]]; then
        log_warn "当前 run.sh 不存在或不可执行: $audit_run_script"
        log_warn "worker 可以先启动并注册；执行审计任务前请确认 Bash 审计工具已安装。"
    fi
}

write_worker_env() {
    local target="$1"
    local worker_token

    if [[ -f "$target" ]]; then
        log_info "已存在密钥文件，不覆盖: $target"
        return 0
    fi

    worker_token="${SUI_AUDIT_WORKER_TOKEN:-}"
    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        printf '\n[Worker Token]\n'
        printf '请填写 master 安装时生成的 Worker Token。\n\n'
        worker_token="$(ask_secret 'Worker Token')"
        [[ -n "$worker_token" ]] || die "Worker Token 不能为空"
    else
        [[ -n "$worker_token" ]] || die "非交互模式必须提供 SUI_AUDIT_WORKER_TOKEN"
    fi

    write_root_file "$target" << EOF
SUI_AUDIT_WORKER_TOKEN=${worker_token}
EOF
    as_root chmod 0600 "$target"
    log_info "已创建密钥文件: $target"
}

maybe_start_service() {
    local start_answer

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        return 0
    fi

    start_answer="$(ask '是否现在启动/重启 worker 服务？0=否 1=是' '1')"
    if [[ "$start_answer" == "1" ]]; then
        as_root systemctl restart "$SERVICE_NAME"
        log_info "服务已启动。查看日志: journalctl -u $SERVICE_NAME -f"
    else
        log_info "稍后可运行: systemctl restart $SERVICE_NAME"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            -h|--help)
                cat << EOF
用法: $0 [--non-interactive]

环境变量:
  SUI_AUDIT_WORKER_DIR
  SUI_AUDIT_WORKER_SERVICE
  SUI_AUDIT_WORKER_NAME
  SUI_AUDIT_WORKER_TAGS
  SUI_AUDIT_MASTER_URL
  SUI_AUDIT_WORKER_POLL_INTERVAL
  SUI_AUDIT_REPO_DIR
  SUI_AUDIT_RUN_SCRIPT
  SUI_AUDIT_WORKER_TOKEN
EOF
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    require_cmd install
    require_cmd systemctl

    local binary_source=""
    if [[ -x "$SCRIPT_DIR/sui-audit-worker" ]]; then
        binary_source="$SCRIPT_DIR/sui-audit-worker"
    elif [[ -x "$SCRIPT_DIR/target/release/sui-audit-worker" ]]; then
        binary_source="$SCRIPT_DIR/target/release/sui-audit-worker"
    else
        die "找不到 sui-audit-worker 二进制；请使用 release 包，或先运行 cargo build --release --bin sui-audit-worker"
    fi

    as_root install -d -m 0755 "$INSTALL_DIR"
    as_root install -m 0755 "$binary_source" "$INSTALL_DIR/sui-audit-worker"

    write_worker_toml "$INSTALL_DIR/worker.toml"

    write_root_file "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=s-ui Audit Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${INSTALL_DIR}/worker.env
ExecStart=${INSTALL_DIR}/sui-audit-worker --config ${INSTALL_DIR}/worker.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    write_worker_env "$INSTALL_DIR/worker.env"

    as_root systemctl daemon-reload
    as_root systemctl enable "$SERVICE_NAME"
    maybe_start_service
    log_info "安装完成"
}

main "$@"

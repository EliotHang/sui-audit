#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SUI_AUDIT_MASTER_DIR:-/opt/sui-audit-master}"
SERVICE_NAME="${SUI_AUDIT_MASTER_SERVICE:-sui-audit-master}"
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

generate_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        date '+%s%N' | sha256sum | awk '{print $1}'
    fi
}

write_master_toml() {
    local target="$1"
    local public_base_url
    local allowed_chat_ids
    local allowed_user_ids
    local bind_addr

    if [[ -f "$target" ]]; then
        log_info "已存在配置，不覆盖: $target"
        return 0
    fi

    bind_addr="${SUI_AUDIT_MASTER_BIND:-127.0.0.1:8787}"
    public_base_url="${SUI_AUDIT_MASTER_PUBLIC_URL:-}"
    allowed_chat_ids="${SUI_AUDIT_TELEGRAM_ALLOWED_CHAT_IDS:-}"
    allowed_user_ids="${SUI_AUDIT_TELEGRAM_ALLOWED_USER_IDS:-}"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        printf '\n[Master 配置]\n'
        printf '如果你暂时只测试 Telegram long polling，Public URL 可以先保留默认值。\n\n'
        public_base_url="$(ask 'Master public URL' "${public_base_url:-https://audit.990829.xyz}")"
        bind_addr="$(ask 'Master listen address' "$bind_addr")"

        printf '\n[Telegram 权限]\n'
        printf 'allowed_chat_ids 和 allowed_user_ids 支持逗号分隔。建议至少填写你的 Telegram user id。\n\n'
        allowed_chat_ids="$(ask 'Allowed Telegram chat IDs' "$allowed_chat_ids")"
        allowed_user_ids="$(ask 'Allowed Telegram user IDs' "$allowed_user_ids")"
    else
        public_base_url="${public_base_url:-https://audit.990829.xyz}"
    fi

    write_root_file "$target" << EOF
[server]
bind = "${bind_addr}"
public_base_url = "${public_base_url}"

[telegram]
mode = "long_poll"
bot_token_env = "SUI_AUDIT_TELEGRAM_BOT_TOKEN"
allowed_chat_ids = [$(toml_string_array "$allowed_chat_ids")]
allowed_user_ids = [$(toml_string_array "$allowed_user_ids")]
poll_timeout_seconds = 20

[worker_auth]
token_env = "SUI_AUDIT_WORKER_TOKEN"

[state]
db_path = "state/master.db"
EOF
    as_root chmod 0600 "$target"
    log_info "已创建配置: $target"
}

write_master_env() {
    local target="$1"
    local bot_token
    local worker_token

    if [[ -f "$target" ]]; then
        log_info "已存在密钥文件，不覆盖: $target"
        return 0
    fi

    bot_token="${SUI_AUDIT_TELEGRAM_BOT_TOKEN:-}"
    worker_token="${SUI_AUDIT_WORKER_TOKEN:-}"

    if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
        printf '\n[Telegram Bot]\n'
        printf '请通过 @BotFather 创建 bot，并把 bot 加入目标会话。\n\n'
        bot_token="$(ask_secret 'Telegram Bot Token')"
        [[ -n "$bot_token" ]] || die "Telegram Bot Token 不能为空"

        printf '\n[Worker Token]\n'
        printf 'Worker token 用于 worker 连接 master。直接回车会自动生成。\n\n'
        worker_token="$(ask_secret 'Worker Token')"
        if [[ -z "$worker_token" ]]; then
            worker_token="$(generate_token)"
            log_info "已自动生成 Worker Token"
        fi
    else
        [[ -n "$bot_token" ]] || log_warn "非交互模式未提供 SUI_AUDIT_TELEGRAM_BOT_TOKEN，master 将无法连接 Telegram"
        if [[ -z "$worker_token" ]]; then
            worker_token="$(generate_token)"
            log_info "非交互模式已自动生成 Worker Token"
        fi
    fi

    write_root_file "$target" << EOF
SUI_AUDIT_TELEGRAM_BOT_TOKEN=${bot_token}
SUI_AUDIT_WORKER_TOKEN=${worker_token}
EOF
    as_root chmod 0600 "$target"
    log_info "已创建密钥文件: $target"
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

maybe_start_service() {
    local start_answer

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        return 0
    fi

    start_answer="$(ask '是否现在启动/重启 master 服务？0=否 1=是' '1')"
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
  SUI_AUDIT_MASTER_DIR
  SUI_AUDIT_MASTER_SERVICE
  SUI_AUDIT_MASTER_PUBLIC_URL
  SUI_AUDIT_MASTER_BIND
  SUI_AUDIT_TELEGRAM_BOT_TOKEN
  SUI_AUDIT_TELEGRAM_ALLOWED_CHAT_IDS
  SUI_AUDIT_TELEGRAM_ALLOWED_USER_IDS
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
    if [[ -x "$SCRIPT_DIR/sui-audit-master" ]]; then
        binary_source="$SCRIPT_DIR/sui-audit-master"
    elif [[ -x "$SCRIPT_DIR/target/release/sui-audit-master" ]]; then
        binary_source="$SCRIPT_DIR/target/release/sui-audit-master"
    else
        die "找不到 sui-audit-master 二进制；请使用 release 包，或先运行 cargo build --release --bin sui-audit-master"
    fi

    as_root install -d -m 0755 "$INSTALL_DIR"
    as_root install -m 0755 "$binary_source" "$INSTALL_DIR/sui-audit-master"

    write_master_toml "$INSTALL_DIR/master.toml"

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

    write_master_env "$INSTALL_DIR/master.env"

    as_root systemctl daemon-reload
    as_root systemctl enable "$SERVICE_NAME"
    maybe_start_service
    log_info "安装完成"
}

main "$@"

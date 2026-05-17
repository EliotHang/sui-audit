#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

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

write_telegram_conf() {
    local conf_file="$1"
    local bot_token
    local chat_id
    local node_name
    local silent
    local restart_service
    local service_name

    if [[ -f "$conf_file" ]]; then
        log_info "已存在 telegram.conf，不覆盖: $conf_file"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        log_warn "非交互模式且 telegram.conf 不存在，跳过生成 Telegram 配置"
        return 0
    fi

    printf '\n[Telegram 配置]\n'
    printf '请先通过 @BotFather 创建 bot，并将 bot 加入目标会话/群组。\n'
    printf '如果暂时不想启用 Telegram，可以直接回车跳过 Bot Token。\n\n'

    bot_token="$(ask_secret 'Telegram Bot Token')"
    if [[ -z "$bot_token" ]]; then
        cat > "$conf_file" <<'EOF_CONF'
TELEGRAM_ENABLED=0
EOF_CONF
        chmod 0600 "$conf_file"
        log_warn "未填写 Bot Token，已生成禁用状态的 telegram.conf"
        return 0
    fi

    chat_id="$(ask 'Telegram Chat ID')"
    [[ -n "$chat_id" ]] || die "Chat ID 不能为空"

    node_name="$(ask '节点名称' "$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'vps')")"
    silent="$(ask '是否静默发送 Telegram 消息？0=否 1=是' '0')"
    restart_service="$(ask '每月清理后是否重启 s-ui 服务？0=否 1=是' '1')"
    service_name="$(ask 's-ui systemd 服务名' 's-ui')"

    cat > "$conf_file" <<EOF_CONF
TELEGRAM_ENABLED=1
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
TELEGRAM_NODE_NAME="$node_name"
TELEGRAM_SEND_MANUAL=0
TELEGRAM_SILENT=$silent
TELEGRAM_PARSE_MODE=""
TELEGRAM_API_BASE="https://api.telegram.org"
TELEGRAM_TIMEOUT=15
RESTART_SERVICE_AFTER_CLEANUP=$restart_service
SUI_SERVICE_NAME="$service_name"
EOF_CONF
    chmod 0600 "$conf_file"
    log_info "已生成 Telegram 配置: $conf_file"
}

write_install_conf() {
    local conf_file="$1"
    local log_file
    local base_url

    if [[ -f "$conf_file" ]]; then
        log_info "已存在安装配置，不覆盖: $conf_file"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        log_warn "非交互模式且安装配置不存在，使用默认日志路径: s-ui.log"
        log_file="s-ui.log"
        base_url="$DEFAULT_BASE_URL"
    else
        printf '\n[日志路径]\n'
        printf '请输入 s-ui 日志文件路径。可以是绝对路径，也可以是相对安装目录的路径。\n'
        printf '如果你的日志不在安装目录，建议填写绝对路径，或提前建立软链接。\n\n'
        log_file="$(ask 's-ui 日志文件路径' 's-ui.log')"

        printf '\n[远程更新]\n'
        printf 'analysis.sh 每次运行前都会从远程刷新；通常保持默认即可。\n\n'
        base_url="$(ask '远程 raw base URL' "$DEFAULT_BASE_URL")"
    fi

    [[ -n "$log_file" ]] || die "日志文件路径不能为空"
    [[ -n "$base_url" ]] || die "远程 raw base URL 不能为空"
    if [[ "$log_file" =~ [[:space:]] ]]; then
        die "日志文件路径包含空格，systemd ExecStart 暂不支持: $log_file"
    fi

    cat > "$conf_file" <<EOF_CONF
SUI_AUDIT_BASE_URL="$base_url"
SUI_AUDIT_ANALYSIS_URL="$base_url/analysis.sh"
SUI_AUDIT_LOG_FILE="$log_file"
EOF_CONF
    chmod 0600 "$conf_file"
    log_info "已生成安装配置: $conf_file"
}

copy_as_root() {
    local src="$1"
    local dst="$2"
    if (( EUID == 0 )); then
        install -m 0644 "$src" "$dst"
    else
        sudo install -m 0644 "$src" "$dst"
    fi
}

systemctl_as_root() {
    if (( EUID == 0 )); then
        systemctl "$@"
    else
        sudo systemctl "$@"
    fi
}

main() {
    NON_INTERACTIVE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            -h|--help)
                printf '用法: %s [--non-interactive]\n' "$0"
                exit 0
                ;;
            *)
                die "未知参数: $1"
                ;;
        esac
    done

    require_cmd systemctl
    require_cmd install
    require_cmd curl
    if (( EUID != 0 )); then
        require_cmd sudo
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$script_dir"

    if [[ "$script_dir" =~ [[:space:]] ]]; then
        die "安装路径包含空格，systemd unit 可能无法可靠运行，请换到无空格路径: $script_dir"
    fi

    local analysis_script="$script_dir/analysis.sh"
    local runner_script="$script_dir/run.sh"
    local telegram_conf="$script_dir/telegram.conf"
    local install_conf="$script_dir/.install.conf"
    local systemd_dir="$script_dir/systemd"
    local daily_args
    local log_file

    [[ -f "$analysis_script" ]] || die "缺少 analysis.sh: $analysis_script"
    [[ -f "$runner_script" ]] || die "缺少 run.sh: $runner_script"
    chmod +x "$analysis_script" "$runner_script" "$script_dir/test_telegram.sh" "$script_dir/update.sh" "$script_dir/bootstrap.sh" "$script_dir/uninstall.sh" 2>/dev/null || true

    write_install_conf "$install_conf"
    write_telegram_conf "$telegram_conf"

    # shellcheck disable=SC1090
    source "$install_conf"
    log_file="${SUI_AUDIT_LOG_FILE:-s-ui.log}"
    [[ -n "$log_file" ]] || die "SUI_AUDIT_LOG_FILE 不能为空"
    if [[ "$log_file" =~ [[:space:]] ]]; then
        die "日志文件路径包含空格，systemd ExecStart 暂不支持: $log_file"
    fi
    daily_args="-f $log_file"

    if [[ -f "$script_dir/users.list" ]]; then
        daily_args="$daily_args -u users.list"
        log_info "检测到 users.list，每日审计将按用户文件过滤"
    else
        log_warn "未检测到 users.list，每日审计将分析日志中的全部用户"
    fi

    mkdir -p "$systemd_dir"

    cat > "$systemd_dir/sui-audit-daily.service" <<EOF_SERVICE
[Unit]
Description=s-ui daily abuse audit

[Service]
Type=oneshot
WorkingDirectory=$script_dir
ExecStart=/usr/bin/env bash $runner_script $daily_args --daily
EOF_SERVICE

    cat > "$systemd_dir/sui-audit-daily.timer" <<'EOF_TIMER'
[Unit]
Description=Run s-ui daily abuse audit

[Timer]
OnCalendar=*-*-* 02:10:00
Persistent=true
Unit=sui-audit-daily.service

[Install]
WantedBy=timers.target
EOF_TIMER

    cat > "$systemd_dir/sui-audit-update.service" <<EOF_SERVICE
[Unit]
Description=s-ui audit support script update check

[Service]
Type=oneshot
WorkingDirectory=$script_dir
ExecStart=/usr/bin/env bash $script_dir/update.sh
EOF_SERVICE

    cat > "$systemd_dir/sui-audit-update.timer" <<'EOF_TIMER'
[Unit]
Description=Check s-ui audit support script updates daily

[Timer]
OnCalendar=*-*-* 01:50:00
Persistent=true
Unit=sui-audit-update.service

[Install]
WantedBy=timers.target
EOF_TIMER

    cat > "$systemd_dir/sui-audit-weekly-summary.service" <<EOF_SERVICE
[Unit]
Description=s-ui audit weekly Telegram summary

[Service]
Type=oneshot
WorkingDirectory=$script_dir
ExecStart=/usr/bin/env bash $runner_script --weekly-summary
EOF_SERVICE

    cat > "$systemd_dir/sui-audit-weekly-summary.timer" <<'EOF_TIMER'
[Unit]
Description=Run s-ui audit weekly Telegram summary

[Timer]
OnCalendar=Mon *-*-* 02:20:00
Persistent=true
Unit=sui-audit-weekly-summary.service

[Install]
WantedBy=timers.target
EOF_TIMER

    cat > "$systemd_dir/sui-audit-cleanup.service" <<EOF_SERVICE
[Unit]
Description=s-ui audit monthly archive cleanup

[Service]
Type=oneshot
WorkingDirectory=$script_dir
ExecStart=/usr/bin/env bash $runner_script --cleanup
EOF_SERVICE

    cat > "$systemd_dir/sui-audit-cleanup.timer" <<'EOF_TIMER'
[Unit]
Description=Run s-ui audit monthly archive cleanup

[Timer]
OnCalendar=*-*-01 02:30:00
Persistent=true
Unit=sui-audit-cleanup.service

[Install]
WantedBy=timers.target
EOF_TIMER

    log_info "安装 systemd unit 到 /etc/systemd/system/"
    copy_as_root "$systemd_dir/sui-audit-daily.service" "/etc/systemd/system/sui-audit-daily.service"
    copy_as_root "$systemd_dir/sui-audit-daily.timer" "/etc/systemd/system/sui-audit-daily.timer"
    copy_as_root "$systemd_dir/sui-audit-update.service" "/etc/systemd/system/sui-audit-update.service"
    copy_as_root "$systemd_dir/sui-audit-update.timer" "/etc/systemd/system/sui-audit-update.timer"
    copy_as_root "$systemd_dir/sui-audit-weekly-summary.service" "/etc/systemd/system/sui-audit-weekly-summary.service"
    copy_as_root "$systemd_dir/sui-audit-weekly-summary.timer" "/etc/systemd/system/sui-audit-weekly-summary.timer"
    copy_as_root "$systemd_dir/sui-audit-cleanup.service" "/etc/systemd/system/sui-audit-cleanup.service"
    copy_as_root "$systemd_dir/sui-audit-cleanup.timer" "/etc/systemd/system/sui-audit-cleanup.timer"

    log_info "重新加载 systemd 并启用 timer"
    systemctl_as_root daemon-reload
    systemctl_as_root enable --now sui-audit-update.timer
    systemctl_as_root enable --now sui-audit-daily.timer
    systemctl_as_root enable --now sui-audit-weekly-summary.timer
    systemctl_as_root enable --now sui-audit-cleanup.timer
    systemctl_as_root restart sui-audit-update.timer sui-audit-daily.timer sui-audit-weekly-summary.timer sui-audit-cleanup.timer

    printf '\n'
    log_info "安装完成。当前定时器:"
    systemctl list-timers --all 'sui-audit-*' || true

    cat <<EOF_DONE

常用命令:
  测试 Telegram:
    $script_dir/test_telegram.sh

  手动运行每日审计:
    sudo systemctl start sui-audit-daily.service

  手动刷新支撑脚本:
    sudo systemctl start sui-audit-update.service

  查看每日审计日志:
    sudo journalctl -u sui-audit-daily.service -n 200 --no-pager

  检查/刷新支撑脚本:
    cd $script_dir && ./update.sh

  卸载 systemd timer/service:
    cd $script_dir && ./uninstall.sh

  完整卸载本工具文件和归档:
    cd $script_dir && ./uninstall.sh --purge

EOF_DONE
}

main "$@"

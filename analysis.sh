#!/usr/bin/env bash
# s-ui日志综合滥用检测脚本 v4.1
# 改进：本地日自动审计、Telegram全用户摘要、每周总结、每月清理并重启服务

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if (( BASH_VERSINFO[0] < 4 )); then
    printf '[ERROR] 需要 Bash 4 或更高版本；Debian 12 默认满足该要求。\n' >&2
    exit 2
fi

SCRIPT_VERSION="4.1.1"

LOG_FILE="s-ui.log"
OUTPUT_PREFIX="sui-滥用检测详细报告-v${SCRIPT_VERSION}"
TOP_N=10
IP_SAMPLE_SIZE=400
KEEP_TEMP=0
USER_FILTER_FILE="users.list"
USE_USER_FILTER=1
USER_FILTER_CREATED=0
DAILY_MODE=0
CLEANUP_MODE=0
CLEANUP_DRY_RUN=0
WEEKLY_SUMMARY_MODE=0
TARGET_DATE=""
SINCE_TIME=""
UNTIL_TIME=""
ARCHIVE_ROOT="archives"
STATE_DIR="state"
NO_ARCHIVE_LOG=0
LOG_ARCHIVE_RETENTION_DAYS=30
REPORT_RETENTION_DAYS=90
WARNING_RETENTION_DAYS=90
AUTOMATION_LOG=""
TELEGRAM_CONFIG_FILE="$SCRIPT_DIR/telegram.conf"
TELEGRAM_ENABLED=0
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_NODE_NAME=""
TELEGRAM_SEND_MANUAL=0
TELEGRAM_SILENT=0
TELEGRAM_API_BASE="https://api.telegram.org"
TELEGRAM_PARSE_MODE=""
TELEGRAM_TIMEOUT=15
RESTART_SERVICE_AFTER_CLEANUP=1
SUI_SERVICE_NAME="s-ui"
LOG_DATE_TZ="${LOG_DATE_TZ:-Asia/Shanghai}"

DATE_SUFFIX="$(TZ="$LOG_DATE_TZ" date '+%Y-%m-%d')"
MD_OUTPUT=""
TEMP_DIR=""
SOURCE_LOG_FILE=""
SLICE_LOG_FILE=""
ANALYSIS_START_EPOCH=""
ANALYSIS_END_EPOCH=""
ANALYSIS_START_KEY=""
ANALYSIS_END_KEY=""
ANALYSIS_LOCAL_START_KEY=""
ANALYSIS_LOCAL_END_KEY=""
ANALYSIS_WINDOW_LABEL=""
ARCHIVED_REPORT=""
ARCHIVED_LOG=""
ARCHIVED_WARNINGS_DIR=""
REASON_SEP=$'\x1f'
ANALYZED_USER_COUNT=0
SKIPPED_USER_COUNT=0

# 风险规则配置
RISK_BT=100
RISK_MULTI_IP_CRITICAL=50
RISK_MULTI_IP_HIGH=30
RISK_MULTI_IP_WATCH=15
RISK_COMMERCIAL=20
RISK_ACTIVE_ALL_DAY=25
RISK_ACTIVE_LONG=10
RISK_TOP_TARGET=15
RISK_BURST=20
RISK_HIGH_RATE=15

MULTI_IP_CRITICAL_THRESHOLD=20
MULTI_IP_HIGH_THRESHOLD=10
MULTI_IP_WATCH_THRESHOLD=5
ACTIVE_ALL_DAY_THRESHOLD=22
ACTIVE_LONG_THRESHOLD=18
TOP_TARGET_MIN_COUNT=1000
TOP_TARGET_CONCENTRATION_THRESHOLD=60
BURST_5MIN_THRESHOLD=300
CONN_PER_HOUR_THRESHOLD=500

BT_PATTERNS="tracker|torrent|bittorrent|hdsky|chdbits|ourbits|m-team|pterclub|announce"
BT_LABEL_PATTERNS="${BT_PATTERNS}|(^|[.-])(pt|bt)([.-]|$)"
COMMERCIAL_PATTERNS="adspower|multilogin|gologin|kameleo|incogniton|selenium|puppeteer"

declare -A USER_RISK_LEVEL
declare -A USER_RISK_SCORE
declare -A USER_RISK_REASONS
declare -A USER_TOTAL_CONN
declare -A USER_IP_COUNT
declare -A USER_TARGET_COUNT
declare -A USER_ACTIVE_HOURS
declare -A USER_TOP_TARGET
declare -A USER_TOP_TARGET_COUNT
declare -A USER_BT_COUNT
declare -A USER_CONN_PER_HOUR
declare -A USER_MAX_5MIN_CONN
declare -A USER_IP_METHOD
declare -A USER_SPAN_HOURS
declare -A USER_FIRST_SEEN
declare -A USER_LAST_SEEN
declare -A USER_MAX_5MIN_WINDOW
declare -A USER_BURST_WINDOWS

HIGH_RISK_COUNT=0
MEDIUM_RISK_COUNT=0
LOW_RISK_COUNT=0
USER_COUNT=0
CONNECTION_ID_MODE=0
LOG_DURATION_HOURS="0.0"
LOG_START_AT=""
LOG_END_AT=""
LOG_DURATION_TEXT="未识别"
CONN_IP_INDEX_FILE=""
CONN_FROM_LINE_INDEX_FILE=""
WARNINGS_DIR=""
LOCK_FD=9

usage() {
    cat << EOF
s-ui 日志滥用检测脚本 v${SCRIPT_VERSION}

用法:
  $0 [日志文件]
  $0 -f s-ui.log -o report-prefix

参数:
  -f, --file FILE          指定 s-ui 日志文件, 默认: s-ui.log
  -o, --output PREFIX      指定输出文件前缀，默认: ${OUTPUT_PREFIX}
  -u, --users FILE         指定用户文件，只分析文件中列出的用户，默认: users.list
      --top-n N            Markdown 报告中展示访问目标 TOP N, 默认: ${TOP_N}
      --sample-size N      每个用户用于估算客户端 IP 的采样连接数，默认: ${IP_SAMPLE_SIZE}
      --all-users          临时分析全部用户，但仍会自动创建默认 users.list
      --daily              分析日志时区昨日 00:00:00 到 23:59:59，并执行归档
      --date YYYY-MM-DD    分析指定日志日期 00:00:00 到 23:59:59，并执行归档
      --since DATETIME     指定分析起始时间，例如 "2026-05-16 00:00:00"
      --until DATETIME     指定分析结束时间，例如 "2026-05-16 23:59:59"
      --archive-root DIR   归档根目录，默认: ${ARCHIVE_ROOT}
      --state-dir DIR      自动化状态目录，默认: ${STATE_DIR}
      --no-archive-log     自动化模式下不归档原始日志切片
      --cleanup            清理过期归档文件
      --cleanup-dry-run    只打印将清理的过期归档文件
      --weekly-summary     汇总最近 7 天归档报告，并发送 Telegram 周报
      --log-retention-days N       日志归档保留天数，默认: ${LOG_ARCHIVE_RETENTION_DAYS}
      --report-retention-days N    报告保留天数，默认: ${REPORT_RETENTION_DAYS}
      --warning-retention-days N   异常窗口日志保留天数，默认: ${WARNING_RETENTION_DAYS}
      --automation-log FILE        自动化运行日志，默认: state/automation.log
      --keep-temp          保留临时目录，便于调试
  -h, --help               显示帮助

输出:
  PREFIX-YYYY-MM-DD.md     人工阅读报告

自动化归档:
  archives/logs/YYYYMM/s-ui-YYYY-MM-DD.log.gz
  archives/reports/YYYYMM/sui-audit-YYYY-MM-DD.md
  archives/warnings/YYYYMM/YYYY-MM-DD/

Telegram:
  如果脚本目录存在 telegram.conf 且 TELEGRAM_ENABLED=1，自动化分析成功后会发送审计摘要
EOF
}

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

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" && "$KEEP_TEMP" -eq 0 ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

on_error() {
    local exit_code=$?
    log_error "脚本在第 ${BASH_LINENO[0]} 行退出，退出码: ${exit_code}，命令: ${BASH_COMMAND}"
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        log_error "临时目录: ${TEMP_DIR}"
    fi
    exit "$exit_code"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                [[ $# -ge 2 ]] || die "$1 需要一个文件路径"
                LOG_FILE="$2"
                shift 2
                ;;
            -o|--output)
                [[ $# -ge 2 ]] || die "$1 需要一个输出前缀"
                OUTPUT_PREFIX="$2"
                shift 2
                ;;
            -u|--users)
                [[ $# -ge 2 ]] || die "$1 需要一个用户文件路径"
                USER_FILTER_FILE="$2"
                USE_USER_FILTER=1
                shift 2
                ;;
            --top-n)
                [[ $# -ge 2 ]] || die "$1 需要一个数字"
                TOP_N="$2"
                shift 2
                ;;
            --sample-size)
                [[ $# -ge 2 ]] || die "$1 需要一个数字"
                IP_SAMPLE_SIZE="$2"
                shift 2
                ;;
            --all-users)
                USE_USER_FILTER=0
                shift
                ;;
            --daily)
                DAILY_MODE=1
                shift
                ;;
            --date)
                [[ $# -ge 2 ]] || die "$1 需要一个 YYYY-MM-DD 日期"
                TARGET_DATE="$2"
                shift 2
                ;;
            --since)
                [[ $# -ge 2 ]] || die "$1 需要一个起始时间"
                SINCE_TIME="$2"
                shift 2
                ;;
            --until)
                [[ $# -ge 2 ]] || die "$1 需要一个结束时间"
                UNTIL_TIME="$2"
                shift 2
                ;;
            --archive-root)
                [[ $# -ge 2 ]] || die "$1 需要一个目录"
                ARCHIVE_ROOT="$2"
                shift 2
                ;;
            --state-dir)
                [[ $# -ge 2 ]] || die "$1 需要一个目录"
                STATE_DIR="$2"
                shift 2
                ;;
            --no-archive-log)
                NO_ARCHIVE_LOG=1
                shift
                ;;
            --cleanup)
                CLEANUP_MODE=1
                shift
                ;;
            --cleanup-dry-run)
                CLEANUP_MODE=1
                CLEANUP_DRY_RUN=1
                shift
                ;;
            --weekly-summary)
                WEEKLY_SUMMARY_MODE=1
                shift
                ;;
            --log-retention-days)
                [[ $# -ge 2 ]] || die "$1 需要一个数字"
                LOG_ARCHIVE_RETENTION_DAYS="$2"
                shift 2
                ;;
            --report-retention-days)
                [[ $# -ge 2 ]] || die "$1 需要一个数字"
                REPORT_RETENTION_DAYS="$2"
                shift 2
                ;;
            --warning-retention-days)
                [[ $# -ge 2 ]] || die "$1 需要一个数字"
                WARNING_RETENTION_DAYS="$2"
                shift 2
                ;;
            --automation-log)
                [[ $# -ge 2 ]] || die "$1 需要一个文件路径"
                AUTOMATION_LOG="$2"
                shift 2
                ;;
            --keep-temp)
                KEEP_TEMP=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "未知参数: $1"
                ;;
            *)
                LOG_FILE="$1"
                shift
                ;;
        esac
    done
}

validate_number() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || die "${name} 必须是非负整数: ${value}"
}

check_dependencies() {
    require_cmd grep
    require_cmd awk
    require_cmd sed
    require_cmd sort
    require_cmd uniq
    require_cmd wc
    require_cmd date
    require_cmd find

    printf 'test\n' | grep -P 'test' >/dev/null 2>&1 || die "当前 grep 不支持 -P；Debian 12 默认 GNU grep 应该支持，请检查环境"

    if [[ "$DAILY_MODE" -eq 1 || -n "$TARGET_DATE" || -n "$SINCE_TIME" || -n "$UNTIL_TIME" || "$CLEANUP_MODE" -eq 1 || "$WEEKLY_SUMMARY_MODE" -eq 1 ]]; then
        require_cmd flock
    fi
    if [[ "$NO_ARCHIVE_LOG" -eq 0 && "$CLEANUP_MODE" -eq 0 && ( "$DAILY_MODE" -eq 1 || -n "$TARGET_DATE" || -n "$SINCE_TIME" || -n "$UNTIL_TIME" ) ]]; then
        require_cmd gzip
    fi
    if should_send_telegram; then
        require_cmd curl
    fi
}

init_runtime() {
    if [[ "$CLEANUP_MODE" -eq 0 ]]; then
        [[ -f "$LOG_FILE" ]] || die "找不到日志文件: $LOG_FILE"
    fi
    validate_number "--top-n" "$TOP_N"
    validate_number "--sample-size" "$IP_SAMPLE_SIZE"
    validate_number "--log-retention-days" "$LOG_ARCHIVE_RETENTION_DAYS"
    validate_number "--report-retention-days" "$REPORT_RETENTION_DAYS"
    validate_number "--warning-retention-days" "$WARNING_RETENTION_DAYS"
    [[ "$TOP_N" -gt 0 ]] || die "--top-n 必须大于 0"
    [[ "$IP_SAMPLE_SIZE" -gt 0 ]] || die "--sample-size 必须大于 0"

    MD_OUTPUT="${OUTPUT_PREFIX}-${DATE_SUFFIX}.md"
    TEMP_DIR="$(mktemp -d -t sui_analysis_XXXXXX)"
    CONN_IP_INDEX_FILE="$TEMP_DIR/conn_ip_index.tsv"
    CONN_FROM_LINE_INDEX_FILE="$TEMP_DIR/conn_from_line_index.tsv"
    WARNINGS_DIR="$PWD/warnings"
    mkdir -p "$WARNINGS_DIR"
    find "$WARNINGS_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.log' -delete
    [[ -n "$AUTOMATION_LOG" ]] || AUTOMATION_LOG="$STATE_DIR/automation.log"
    trap cleanup EXIT
    trap on_error ERR
}

load_telegram_config() {
    [[ -f "$TELEGRAM_CONFIG_FILE" ]] || return 0
    # shellcheck disable=SC1090
    source "$TELEGRAM_CONFIG_FILE"
    [[ -n "$TELEGRAM_NODE_NAME" ]] || TELEGRAM_NODE_NAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host')"
}

is_window_mode() {
    [[ "$DAILY_MODE" -eq 1 || -n "$TARGET_DATE" || -n "$SINCE_TIME" || -n "$UNTIL_TIME" ]]
}

should_send_telegram() {
    [[ "$TELEGRAM_ENABLED" -eq 1 ]] || return 1
    [[ "$CLEANUP_MODE" -eq 0 ]] || return 1
    if is_window_mode || [[ "$TELEGRAM_SEND_MANUAL" -eq 1 ]]; then
        return 0
    fi
    return 1
}

format_log_time_local() {
    local raw="${1:-}"

    if [[ "$raw" =~ ^[+-][0-9]{4}[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        # 报告中直接显示日志自带时间，不做时区转换。
        printf '%s %s' "${raw:6:10}" "${raw:17:8} ${raw:0:5}"
        return 0
    fi
    printf '%s' "$raw"
}

log_automation_event() {
    local message="$*"
    mkdir -p "$STATE_DIR"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$AUTOMATION_LOG"
}

count_warning_logs() {
    if [[ -n "$ARCHIVED_WARNINGS_DIR" && -d "$ARCHIVED_WARNINGS_DIR" ]]; then
        find "$ARCHIVED_WARNINGS_DIR" -maxdepth 1 -type f -name '*.log' | wc -l | tr -d ' '
    elif [[ -d "$WARNINGS_DIR" ]]; then
        find "$WARNINGS_DIR" -maxdepth 1 -type f -name '*.log' | wc -l | tr -d ' '
    else
        printf '0'
    fi
}

plain_risk_reason() {
    local reasons="${1:-}"
    reasons="${reasons//$REASON_SEP/; }"
    reasons="${reasons//\*\*/}"
    printf '%s' "$reasons"
}

telegram_all_users_summary() {
    local users_file="$TEMP_DIR/telegram_all_users.tsv"
    local user_bracket
    local user
    local reasons

    : > "$users_file"
    [[ -s "$TEMP_DIR/users.txt" ]] || return 0

    while IFS= read -r user_bracket; do
        [[ -n "$user_bracket" ]] || continue
        user="${user_bracket#\[}"
        user="${user%\]}"
        reasons="$(plain_risk_reason "${USER_RISK_REASONS[$user]:-无}")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${USER_RISK_SCORE[$user]:-0}" \
            "$user_bracket" \
            "${USER_RISK_LEVEL[$user]:-🟢 低风险}" \
            "${USER_TOTAL_CONN[$user]:-0}" \
            "${USER_IP_COUNT[$user]:-0}" \
            "${USER_MAX_5MIN_CONN[$user]:-0}" \
            "$reasons" >> "$users_file"
    done < "$TEMP_DIR/users.txt"

    if [[ ! -s "$users_file" ]]; then
        printf '无用户数据。\n'
        return 0
    fi

    sort -t $'\t' -k1,1nr -k4,4nr "$users_file" | \
        awk -F '\t' '{
            printf "- %s %s | %s分 | 连接%s | IP%s | 峰值%s\n  %s\n", $3, $2, $1, $4, $5, $6, $7
        }'
}

telegram_top_users_by_metric() {
    local metric="$1"
    local title="$2"
    local users_file="$TEMP_DIR/telegram_top_${metric}.tsv"
    local user_bracket
    local user
    local value

    : > "$users_file"
    [[ -s "$TEMP_DIR/users.txt" ]] || return 0

    while IFS= read -r user_bracket; do
        [[ -n "$user_bracket" ]] || continue
        user="${user_bracket#\[}"
        user="${user%\]}"
        case "$metric" in
            total_conn) value="${USER_TOTAL_CONN[$user]:-0}" ;;
            ip_count) value="${USER_IP_COUNT[$user]:-0}" ;;
            burst) value="${USER_MAX_5MIN_CONN[$user]:-0}" ;;
            *) value=0 ;;
        esac
        printf '%s\t%s\n' "$value" "$user_bracket" >> "$users_file"
    done < "$TEMP_DIR/users.txt"

    printf '%s\n' "$title"
    sort -t $'\t' -k1,1nr "$users_file" | awk -F '\t' 'NR <= 3 {printf "- %s: %s\n", $2, $1}'
}

telegram_burst_summary() {
    local users_file="$TEMP_DIR/telegram_burst.tsv"
    local warning_users
    local user_bracket
    local user

    warning_users="$(count_warning_logs)"
    : > "$users_file"

    if [[ -s "$TEMP_DIR/users.txt" ]]; then
        while IFS= read -r user_bracket; do
            [[ -n "$user_bracket" ]] || continue
            user="${user_bracket#\[}"
            user="${user%\]}"
            printf '%s\t%s\t%s\n' "${USER_MAX_5MIN_CONN[$user]:-0}" "$user_bracket" "${USER_MAX_5MIN_WINDOW[$user]:-未识别}" >> "$users_file"
        done < "$TEMP_DIR/users.txt"
    fi

    if [[ -s "$users_file" ]]; then
        sort -t $'\t' -k1,1nr "$users_file" | awk -F '\t' -v warning_users="$warning_users" 'NR == 1 {
            printf "异常窗口用户: %s\n最高5分钟峰值: %s %s次 @ %s\n", warning_users, $2, $1, $3
        }'
    else
        printf '异常窗口用户: %s\n最高5分钟峰值: 无\n' "$warning_users"
    fi
}

build_telegram_message() {
    local window="${ANALYSIS_WINDOW_LABEL:-完整日志}"
    local total_conn
    local total_bt
    local user_bracket
    local user

    total_conn=0
    total_bt=0
    if [[ -s "$TEMP_DIR/users.txt" ]]; then
        while IFS= read -r user_bracket; do
            [[ -n "$user_bracket" ]] || continue
            user="${user_bracket#\[}"
            user="${user%\]}"
            total_conn=$((total_conn + ${USER_TOTAL_CONN[$user]:-0}))
            total_bt=$((total_bt + ${USER_BT_COUNT[$user]:-0}))
        done < "$TEMP_DIR/users.txt"
    fi

    cat << EOF
🔎 s-ui 每日审计
节点: ${TELEGRAM_NODE_NAME}
窗口: ${window}

📌 总览
用户: ${USER_COUNT} | 连接: ${total_conn}
风险: 🔴${HIGH_RISK_COUNT} 🟡${MEDIUM_RISK_COUNT} 🟢${LOW_RISK_COUNT} ⚪${SKIPPED_USER_COUNT}
BT/PT命中: ${total_bt}

⚡ 突发连接
$(telegram_burst_summary)

👥 全部用户
$(telegram_all_users_summary)

📊 排行
$(telegram_top_users_by_metric total_conn "连接数 Top 3")
$(telegram_top_users_by_metric ip_count "IP数 Top 3")
EOF
}

send_telegram_message() {
    local message="$1"
    local api_url
    local curl_args

    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log_error "Telegram 已启用，但 TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID 为空，跳过发送"
        log_automation_event "[WARN] telegram skipped: missing token or chat id"
        return 0
    fi

    api_url="${TELEGRAM_API_BASE%/}/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    curl_args=(
        --silent --show-error --fail
        --max-time "$TELEGRAM_TIMEOUT"
        --request POST "$api_url"
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
        --data-urlencode "text=${message}"
        --data-urlencode "disable_notification=${TELEGRAM_SILENT}"
    )

    if [[ -n "$TELEGRAM_PARSE_MODE" ]]; then
        curl_args+=(--data-urlencode "parse_mode=${TELEGRAM_PARSE_MODE}")
    fi

    if curl "${curl_args[@]}" >/dev/null; then
        log_info "Telegram 审计摘要已发送"
        log_automation_event "[INFO] telegram sent"
    else
        log_error "Telegram 审计摘要发送失败"
        log_automation_event "[WARN] telegram send failed"
    fi
}

send_telegram_summary_if_enabled() {
    local message

    should_send_telegram || return 0
    message="$(build_telegram_message)"
    send_telegram_message "$message"
}

build_weekly_summary_message() {
    local today
    local date_key
    local report_file
    local high
    local medium
    local low
    local users
    local total_high=0
    local total_medium=0
    local total_low=0
    local days_found=0
    local rows=""
    local i

    today="$(TZ="$LOG_DATE_TZ" date '+%Y-%m-%d')"
    for i in 1 2 3 4 5 6 7; do
        date_key="$(TZ="$LOG_DATE_TZ" date -d "$today - $i day" '+%Y-%m-%d')"
        report_file="$ARCHIVE_ROOT/reports/${date_key:0:4}${date_key:5:2}/sui-audit-$date_key.md"
        if [[ -f "$report_file" ]]; then
            high="$(grep -m1 '高风险用户' "$report_file" | grep -oP '[0-9]+' | head -n 1 || printf '0')"
            medium="$(grep -m1 '中风险用户' "$report_file" | grep -oP '[0-9]+' | head -n 1 || printf '0')"
            low="$(grep -m1 '低风险用户' "$report_file" | grep -oP '[0-9]+' | head -n 1 || printf '0')"
            users="$(grep -m1 '^总用户数:' "$report_file" | grep -oP '[0-9]+' | head -n 1 || printf '0')"
            total_high=$((total_high + high))
            total_medium=$((total_medium + medium))
            total_low=$((total_low + low))
            days_found=$((days_found + 1))
            rows="${rows}- ${date_key}: 用户${users} 🔴${high} 🟡${medium} 🟢${low}"$'\n'
        else
            rows="${rows}- ${date_key}: 无归档报告"$'\n'
        fi
    done

    cat << EOF
📅 s-ui 每周审计总结
节点: ${TELEGRAM_NODE_NAME}
范围: 最近 7 个本地日

📌 汇总
有效日报: ${days_found}/7
累计风险: 🔴${total_high} 🟡${total_medium} 🟢${total_low}

📆 每日概览
${rows}
EOF
}

send_weekly_summary() {
    local message

    if [[ "$TELEGRAM_ENABLED" -ne 1 ]]; then
        log_info "Telegram 未启用，跳过每周总结发送"
        return 0
    fi
    require_cmd curl
    message="$(build_weekly_summary_message)"
    send_telegram_message "$message"
}

acquire_lock() {
    mkdir -p "$STATE_DIR"
    exec {LOCK_FD}>"$STATE_DIR/run.lock"
    if ! flock -n "$LOCK_FD"; then
        die "已有自动化任务正在运行: $STATE_DIR/run.lock"
    fi
}

parse_date_window() {
    local start_text
    local end_text

    if [[ -n "$SINCE_TIME" || -n "$UNTIL_TIME" ]]; then
        [[ -n "$SINCE_TIME" && -n "$UNTIL_TIME" ]] || die "--since 和 --until 必须同时指定"
        start_text="$SINCE_TIME"
        end_text="$UNTIL_TIME"
        TARGET_DATE="${SINCE_TIME:0:10}"
    elif [[ -n "$TARGET_DATE" ]]; then
        [[ "$TARGET_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date 格式必须是 YYYY-MM-DD: $TARGET_DATE"
        start_text="$TARGET_DATE 00:00:00"
        end_text="$TARGET_DATE 23:59:59"
    elif [[ "$DAILY_MODE" -eq 1 ]]; then
        TARGET_DATE="$(TZ="$LOG_DATE_TZ" date -d 'yesterday' '+%Y-%m-%d')"
        start_text="$TARGET_DATE 00:00:00"
        end_text="$TARGET_DATE 23:59:59"
    else
        return 0
    fi

    ANALYSIS_START_EPOCH="$(date -d "$start_text" '+%s' 2>/dev/null || true)"
    ANALYSIS_END_EPOCH="$(date -d "$end_text" '+%s' 2>/dev/null || true)"
    [[ -n "$ANALYSIS_START_EPOCH" ]] || die "无法解析起始时间: $start_text"
    [[ -n "$ANALYSIS_END_EPOCH" ]] || die "无法解析结束时间: $end_text"
    [[ "$ANALYSIS_END_EPOCH" -ge "$ANALYSIS_START_EPOCH" ]] || die "结束时间不能早于起始时间"

    DATE_SUFFIX="$TARGET_DATE"
    ANALYSIS_LOCAL_START_KEY="$start_text"
    ANALYSIS_LOCAL_END_KEY="$end_text"
    # 直接按日志里的本地时间字段切片，不做时区转换。
    ANALYSIS_START_KEY="$start_text"
    ANALYSIS_END_KEY="$end_text"
    ANALYSIS_WINDOW_LABEL="$start_text ~ $end_text 日志时间"
    MD_OUTPUT="$TEMP_DIR/sui-audit-$TARGET_DATE.md"
    SLICE_LOG_FILE="$TEMP_DIR/s-ui-$TARGET_DATE.slice.log"
}

slice_log_by_window() {
    local source_file="$1"
    local output_file="$2"

    log_info "正在切分分析窗口日志: ${ANALYSIS_WINDOW_LABEL}"
    log_info "对应日志时间窗口: ${ANALYSIS_START_KEY} ~ ${ANALYSIS_END_KEY}"
    awk -v start="$ANALYSIS_START_KEY" -v end="$ANALYSIS_END_KEY" '
        $1 ~ /^[+-][0-9][0-9][0-9][0-9]$/ &&
        $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ &&
        $3 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
            line_time = $2 " " $3
            if (line_time >= start && line_time <= end) {
                print
            }
        }
    ' "$source_file" > "$output_file"

    log_info "日志切片完成: $(wc -l < "$output_file" | tr -d ' ') 行"
}

archive_file_atomic() {
    local source_file="$1"
    local target_file="$2"
    local tmp_file="${target_file}.tmp"

    mkdir -p "$(dirname "$target_file")"
    cp "$source_file" "$tmp_file"
    mv "$tmp_file" "$target_file"
}

archive_gzip_atomic() {
    local source_file="$1"
    local target_file="$2"
    local tmp_file="${target_file}.tmp"

    mkdir -p "$(dirname "$target_file")"
    gzip -c "$source_file" > "$tmp_file"
    mv "$tmp_file" "$target_file"
}

archive_daily_outputs() {
    local month_dir="${TARGET_DATE:0:4}${TARGET_DATE:5:2}"
    local report_target="$ARCHIVE_ROOT/reports/$month_dir/sui-audit-$TARGET_DATE.md"
    local log_target="$ARCHIVE_ROOT/logs/$month_dir/s-ui-$TARGET_DATE.log.gz"
    local warnings_target="$ARCHIVE_ROOT/warnings/$month_dir/$TARGET_DATE"

    archive_file_atomic "$MD_OUTPUT" "$report_target"
    ARCHIVED_REPORT="$report_target"

    if [[ "$NO_ARCHIVE_LOG" -eq 0 ]]; then
        archive_gzip_atomic "$SLICE_LOG_FILE" "$log_target"
        ARCHIVED_LOG="$log_target"
    fi

    mkdir -p "$warnings_target"
    find "$warnings_target" -mindepth 1 -maxdepth 1 -type f -delete
    if find "$WARNINGS_DIR" -maxdepth 1 -type f -name '*.log' | grep -q .; then
        find "$WARNINGS_DIR" -maxdepth 1 -type f -name '*.log' -exec cp {} "$warnings_target/" \;
    else
        printf '# %s\n\n当日无 5 分钟突发连接异常窗口。\n' "$TARGET_DATE" > "$warnings_target/README.md"
    fi
    ARCHIVED_WARNINGS_DIR="$warnings_target"

    MD_OUTPUT="$ARCHIVED_REPORT"
}

cleanup_path_files() {
    local target_dir="$1"
    local retention_days="$2"
    local name_pattern="$3"

    [[ -d "$target_dir" ]] || return 0
    case "$target_dir" in
        "$ARCHIVE_ROOT"/*) ;;
        *) die "拒绝清理非归档目录: $target_dir" ;;
    esac

    if [[ "$CLEANUP_DRY_RUN" -eq 1 ]]; then
        find "$target_dir" -type f -name "$name_pattern" -mtime +"$retention_days" -print
    else
        find "$target_dir" -type f -name "$name_pattern" -mtime +"$retention_days" -print -delete
    fi
}

cleanup_empty_dirs() {
    local target_dir="$1"

    [[ -d "$target_dir" ]] || return 0
    case "$target_dir" in
        "$ARCHIVE_ROOT"/*) ;;
        *) die "拒绝清理非归档目录: $target_dir" ;;
    esac
    find "$target_dir" -mindepth 1 -type d -empty -print -delete
}

cleanup_archives() {
    log_info "开始清理过期归档，dry-run=${CLEANUP_DRY_RUN}"
    cleanup_path_files "$ARCHIVE_ROOT/logs" "$LOG_ARCHIVE_RETENTION_DAYS" '*.log.gz'
    cleanup_path_files "$ARCHIVE_ROOT/reports" "$REPORT_RETENTION_DAYS" '*.md'
    cleanup_path_files "$ARCHIVE_ROOT/warnings" "$WARNING_RETENTION_DAYS" '*.log'
    cleanup_path_files "$ARCHIVE_ROOT/warnings" "$WARNING_RETENTION_DAYS" 'README.md'
    if [[ "$CLEANUP_DRY_RUN" -eq 0 ]]; then
        cleanup_empty_dirs "$ARCHIVE_ROOT/logs"
        cleanup_empty_dirs "$ARCHIVE_ROOT/reports"
        cleanup_empty_dirs "$ARCHIVE_ROOT/warnings"
    fi
    log_info "清理完成"
}

restart_sui_service_if_enabled() {
    if [[ "$CLEANUP_DRY_RUN" -eq 1 || "$RESTART_SERVICE_AFTER_CLEANUP" -ne 1 ]]; then
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "未找到 systemctl，跳过重启 ${SUI_SERVICE_NAME}"
        log_automation_event "[WARN] systemctl missing, skip restart service=${SUI_SERVICE_NAME}"
        return 0
    fi

    log_info "清理完成后重启服务: ${SUI_SERVICE_NAME}"
    if systemctl restart "$SUI_SERVICE_NAME"; then
        log_automation_event "[INFO] restarted service=${SUI_SERVICE_NAME}"
    else
        log_error "重启服务失败: ${SUI_SERVICE_NAME}"
        log_automation_event "[WARN] restart failed service=${SUI_SERVICE_NAME}"
    fi
}

reasons_for_summary() {
    local reasons="${1:-}"
    printf '%s' "${reasons//$REASON_SEP/; }"
}

append_reason() {
    local current="${1:-}"
    local reason="${2:-}"

    if [[ -z "$reason" ]]; then
        printf '%s' "$current"
    elif [[ -z "$current" ]]; then
        printf '%s' "$reason"
    else
        printf '%s%s%s' "$current" "$REASON_SEP" "$reason"
    fi
}

format_duration_from_seconds() {
    local total_seconds="${1:-0}"
    local days hours minutes seconds

    if [[ -z "$total_seconds" || "$total_seconds" -lt 0 ]]; then
        printf '未识别'
        return 0
    fi

    days=$((total_seconds / 86400))
    hours=$(((total_seconds % 86400) / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if [[ "$days" -gt 0 ]]; then
        printf '%d天%02d小时%02d分%02d秒' "$days" "$hours" "$minutes" "$seconds"
    elif [[ "$hours" -gt 0 ]]; then
        printf '%d小时%02d分%02d秒' "$hours" "$minutes" "$seconds"
    elif [[ "$minutes" -gt 0 ]]; then
        printf '%d分%02d秒' "$minutes" "$seconds"
    else
        printf '%d秒' "$seconds"
    fi
}

normalize_user_filter() {
    local source_file="$1"
    local normalized_file="$TEMP_DIR/users_filter.txt"
    local raw_line
    local trimmed

    : > "$normalized_file"
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        trimmed="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$raw_line")"
        [[ -n "$trimmed" ]] || continue
        [[ "$trimmed" == \#* ]] && continue

        if [[ "$trimmed" =~ ^\[[a-zA-Z0-9_-]+\]$ ]]; then
            printf '%s\n' "$trimmed" >> "$normalized_file"
        else
            printf '[%s]\n' "$trimmed" >> "$normalized_file"
        fi
    done < "$source_file"

    sort -u "$normalized_file" -o "$normalized_file"
}

discover_users_from_log() {
    local source_file="$1"
    local output_file="$2"

    { grep -oP '\[[a-zA-Z0-9_-]+\](?= inbound (packet )?connection to)' "$source_file" || true; } | \
        { grep -Ev '^\[(718|socks|vless-reality.*|shadowsocks.*|trojan.*|vmess.*|vless-.*)\]$' || true; } | \
        sort | uniq > "$output_file"
}

ensure_user_filter_file() {
    local target_file="$1"
    local discovered_file="$2"
    local target_dir

    [[ -n "$target_file" ]] || return 0
    [[ -f "$target_file" ]] && return 0

    target_dir="$(dirname "$target_file")"
    if [[ "$target_dir" != "." ]]; then
        mkdir -p "$target_dir"
    fi
    cp "$discovered_file" "$target_file"
    USER_FILTER_CREATED=1
    log_info "已创建用户列表: ${target_file}（默认包含当前日志中的全部用户）"
}

extract_users() {
    local discovered_users_file="$TEMP_DIR/users.discovered.txt"
    local user_list_seed_file="$TEMP_DIR/users.list.seed.txt"

    log_info "正在提取用户列表..."

    discover_users_from_log "$LOG_FILE" "$discovered_users_file"

    cp "$discovered_users_file" "$TEMP_DIR/users.txt"

    if [[ -n "$USER_FILTER_FILE" ]]; then
        if [[ -n "$SOURCE_LOG_FILE" && -f "$SOURCE_LOG_FILE" ]]; then
            discover_users_from_log "$SOURCE_LOG_FILE" "$user_list_seed_file"
        else
            cp "$discovered_users_file" "$user_list_seed_file"
        fi
        ensure_user_filter_file "$USER_FILTER_FILE" "$user_list_seed_file"
        if [[ "$USE_USER_FILTER" -eq 1 ]]; then
            normalize_user_filter "$USER_FILTER_FILE"
            grep -Fxf "$TEMP_DIR/users_filter.txt" "$TEMP_DIR/users.txt" > "$TEMP_DIR/users.filtered.txt" || true
            mv "$TEMP_DIR/users.filtered.txt" "$TEMP_DIR/users.txt"
            log_info "已按用户文件过滤: ${USER_FILTER_FILE}"
        else
            log_info "已跳过用户文件过滤，本次分析全部用户: ${USER_FILTER_FILE}"
        fi
    fi

    USER_COUNT="$(wc -l < "$TEMP_DIR/users.txt" | tr -d ' ')"
    log_info "发现 ${USER_COUNT} 个用户"
}

detect_log_capabilities() {
    local conn_id_count

    conn_id_count="$({ grep -oP '\[[0-9]+ [0-9]+ms\]' "$LOG_FILE" || true; } | awk 'NR <= 20 {count++} END {print count+0}')"
    if [[ "$conn_id_count" -gt 0 ]]; then
        CONNECTION_ID_MODE=1
        log_info "检测到 sing-box 连接ID日志，客户端IP将优先按连接ID精确关联"
    else
        CONNECTION_ID_MODE=0
        log_info "未检测到连接ID日志，客户端IP将回退到邻近行估算"
    fi
}

build_conn_ip_index() {
    if [[ "$CONNECTION_ID_MODE" -eq 0 ]]; then
        return 0
    fi

    log_info "正在建立连接ID到源IP的索引..."
    { grep 'inbound connection from' "$LOG_FILE" || true; } | \
        sed -nE 's/.*\[([0-9]+) [^]]+\].*inbound connection from \[?([0-9A-Fa-f:.]+)\]?:[0-9]+.*/\1\t\2/p' | \
        awk '!seen[$1]++' > "$CONN_IP_INDEX_FILE"
    log_info "连接ID索引完成: $(wc -l < "$CONN_IP_INDEX_FILE" | tr -d ' ') 条"
}

build_conn_from_line_index() {
    log_info "正在建立来源IP行号索引..."
    { grep -n 'inbound connection from' "$LOG_FILE" || true; } | \
        sed -nE 's/^([0-9]+):.*inbound connection from \[?([0-9A-Fa-f:.]+)\]?:[0-9]+.*/\1\t\2/p' \
        > "$CONN_FROM_LINE_INDEX_FILE"
    log_info "来源IP行号索引完成: $(wc -l < "$CONN_FROM_LINE_INDEX_FILE" | tr -d ' ') 条"
}

build_user_connection_logs() {
    if [[ ! -s "$TEMP_DIR/users.txt" ]]; then
        return 0
    fi

    log_info "正在预切分用户连接日志..."
    awk -v outdir="$TEMP_DIR" '
        NR == FNR {
            wanted[$0] = 1
            next
        }
        /inbound (packet )?connection to/ {
            if (match($0, /\[[a-zA-Z0-9_-]+\] inbound (packet )?connection to/)) {
                user = substr($0, RSTART, RLENGTH)
                sub(/^\[/, "", user)
                sub(/\] inbound (packet )?connection to$/, "", user)
                key = "[" user "]"
                if (key in wanted) {
                    print >> (outdir "/user_" user "_connections.log")
                }
            }
        }
    ' "$TEMP_DIR/users.txt" "$LOG_FILE"
    log_info "用户连接日志切分完成"
}

calculate_log_duration() {
    local first_line
    local last_line
    local first_epoch
    local last_epoch
    local duration_seconds

    first_line="$({ grep -oP '^[+-][0-9]{4} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" || true; } | awk 'NR == 1 {print; exit}')"
    last_line="$({ grep -oP '^[+-][0-9]{4} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE" || true; } | tail -n 1)"

    LOG_START_AT="$first_line"
    LOG_END_AT="$last_line"

    if [[ -n "$first_line" && -n "$last_line" ]]; then
        first_epoch="$(date -d "${first_line:6:10} ${first_line:17:8} ${first_line:0:5}" '+%s' 2>/dev/null || true)"
        last_epoch="$(date -d "${last_line:6:10} ${last_line:17:8} ${last_line:0:5}" '+%s' 2>/dev/null || true)"
    else
        first_epoch=""
        last_epoch=""
    fi

    if [[ -n "$first_epoch" && -n "$last_epoch" && "$last_epoch" -ge "$first_epoch" ]]; then
        duration_seconds=$((last_epoch - first_epoch + 1))
        LOG_DURATION_HOURS="$(awk "BEGIN {hours=$duration_seconds / 3600; if (hours < 0.1) hours=0.1; printf \"%.1f\", hours}")"
        LOG_DURATION_TEXT="$(format_duration_from_seconds "$duration_seconds")"
        LOG_START_AT="$(format_log_time_local "$first_line")"
        LOG_END_AT="$(format_log_time_local "$last_line")"
    else
        LOG_DURATION_HOURS="0.0"
        LOG_DURATION_TEXT="未识别"
        [[ -n "$LOG_START_AT" ]] || LOG_START_AT="未识别"
        [[ -n "$LOG_END_AT" ]] || LOG_END_AT="未识别"
    fi
}

init_reports() {
    local display_log_file="${SOURCE_LOG_FILE:-$LOG_FILE}"
    local report_archive_hint="未启用"
    local log_archive_hint="未启用"
    local warnings_archive_hint="未启用"
    local month_dir

    if is_window_mode; then
        month_dir="${TARGET_DATE:0:4}${TARGET_DATE:5:2}"
        report_archive_hint="$ARCHIVE_ROOT/reports/$month_dir/sui-audit-$TARGET_DATE.md"
        if [[ "$NO_ARCHIVE_LOG" -eq 0 ]]; then
            log_archive_hint="$ARCHIVE_ROOT/logs/$month_dir/s-ui-$TARGET_DATE.log.gz"
        else
            log_archive_hint="已禁用"
        fi
        warnings_archive_hint="$ARCHIVE_ROOT/warnings/$month_dir/$TARGET_DATE"
    fi

    cat > "$MD_OUTPUT" << EOF
# 🔍 s-ui 日志滥用检测详细报告 v${SCRIPT_VERSION}

## 📋 报告说明

本报告通过分析 s-ui 面板日志，识别以下滥用行为：
- 🔴 **多IP登录** - 账号共享/转卖
- 🔴 **BT/PT下载** - 违反使用条款
- 🟡 **商业用途** - 指纹浏览器、自动化脚本
- 🟡 **异常高频** - 可能的撞库/爬虫
- 🟡 **24小时活跃** - 多人共享
- 🟡 **突发连接** - 短时间自动化/爬虫特征

---

分析时间: $(TZ="$LOG_DATE_TZ" date '+%Y年%m月%d日 %H:%M:%S')
日志文件: ${display_log_file}
用户过滤文件: ${USER_FILTER_FILE:-未指定}
用户过滤启用: ${USE_USER_FILTER}
用户列表自动创建: ${USER_FILTER_CREATED}
自动化窗口: ${ANALYSIS_WINDOW_LABEL:-完整日志}
归档根目录: ${ARCHIVE_ROOT}
报告归档路径: ${report_archive_hint}
日志归档路径: ${log_archive_hint}
异常窗口归档目录: ${warnings_archive_hint}
总用户数: ${USER_COUNT}
连接ID关联: ${CONNECTION_ID_MODE}
日志开始时间: ${LOG_START_AT:-未识别}
日志结束时间: ${LOG_END_AT:-未识别}
日志覆盖小时数: ${LOG_DURATION_HOURS}
日志覆盖时长: ${LOG_DURATION_TEXT}
脚本版本: v${SCRIPT_VERSION}

---

EOF
}

extract_user_base_data() {
    local user_bracket="$1"
    local user="$2"
    local user_log="$TEMP_DIR/user_${user}_connections.log"
    local targets_file="$TEMP_DIR/user_${user}_targets.txt"
    local first_seen
    local last_seen
    local first_epoch
    local last_epoch
    local span_seconds
    local burst_summary
    local burst_summary_file="$TEMP_DIR/user_${user}_burst_summary.tsv"
    local burst_line
    local burst_type
    local burst_window
    local burst_count

    if [[ ! -f "$user_log" ]]; then
        grep -F "$user_bracket" "$LOG_FILE" | grep -E "inbound (packet )?connection to" > "$user_log" || true
    fi
    [[ -s "$user_log" ]] || return 1

    USER_TOTAL_CONN["$user"]="$(wc -l < "$user_log" | tr -d ' ')"

    USER_ACTIVE_HOURS["$user"]="$(
        awk '
            $1 ~ /^[+-][0-9][0-9][0-9][0-9]$/ &&
            $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ &&
            $3 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
                print substr($3, 1, 2)
            }
        ' "$user_log" | sort | uniq | wc -l | tr -d ' '
    )"

    { grep -oP 'inbound (?:packet )?connection to \K(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(?=:[0-9]+)' "$user_log" || true; } | \
        sort | uniq -c | sort -rn > "$targets_file"

    USER_TARGET_COUNT["$user"]="$(wc -l < "$targets_file" | tr -d ' ')"

    first_seen="$({ grep -oP '^[+-][0-9]{4} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$user_log" || true; } | awk 'NR == 1 {print; exit}')"
    last_seen="$({ grep -oP '^[+-][0-9]{4} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$user_log" || true; } | tail -n 1)"
    if [[ -n "$first_seen" && -n "$last_seen" ]]; then
        first_epoch="$(date -d "${first_seen:6:10} ${first_seen:17:8} ${first_seen:0:5}" '+%s' 2>/dev/null || true)"
        last_epoch="$(date -d "${last_seen:6:10} ${last_seen:17:8} ${last_seen:0:5}" '+%s' 2>/dev/null || true)"
    else
        first_epoch=""
        last_epoch=""
    fi

    if [[ -n "$first_epoch" && -n "$last_epoch" && "$last_epoch" -ge "$first_epoch" ]]; then
        span_seconds=$((last_epoch - first_epoch + 1))
        USER_SPAN_HOURS["$user"]="$(awk "BEGIN {hours=$span_seconds / 3600; if (hours < 0.1) hours=0.1; printf \"%.1f\", hours}")"
    else
        USER_SPAN_HOURS["$user"]="0.0"
    fi

    USER_FIRST_SEEN["$user"]="$(format_log_time_local "$first_seen")"
    USER_LAST_SEEN["$user"]="$(format_log_time_local "$last_seen")"

    USER_CONN_PER_HOUR["$user"]="$(
        awk -v total="${USER_TOTAL_CONN[$user]}" -v span="${USER_SPAN_HOURS[$user]}" -v active="${USER_ACTIVE_HOURS[$user]}" \
            'BEGIN {
                base = span + 0
                if (base <= 0) base = active + 0
                if (base <= 0) base = 1
                printf "%.1f", total / base
            }'
    )"
    awk -v threshold="$BURST_5MIN_THRESHOLD" '
        $1 ~ /^[+-][0-9][0-9][0-9][0-9]$/ &&
        $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ &&
        $3 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
            hour = substr($3, 1, 2)
            minute = substr($3, 4, 2) + 0
            bucket = $2 " " hour ":" sprintf("%02d", int(minute / 5) * 5)
            count[bucket]++
        }
        END {
            max = 0
            target = ""
            for (b in count) {
                if (count[b] > max) {
                    max = count[b]
                    target = b
                }
            }
            printf "MAX\t%s\t%d\n", target, max
            for (b in count) {
                if (count[b] >= threshold) {
                    printf "WARN\t%s\t%d\n", b, count[b]
                }
            }
        }
    ' "$user_log" > "$burst_summary_file"

    USER_MAX_5MIN_WINDOW["$user"]="未识别"
    USER_MAX_5MIN_CONN["$user"]="0"
    USER_BURST_WINDOWS["$user"]=""

    while IFS=$'\t' read -r burst_type burst_window burst_count; do
        [[ -n "${burst_type:-}" ]] || continue
        if [[ "$burst_type" == "MAX" ]]; then
            USER_MAX_5MIN_WINDOW["$user"]="${burst_window:-未识别}"
            USER_MAX_5MIN_CONN["$user"]="${burst_count:-0}"
        elif [[ "$burst_type" == "WARN" ]]; then
            USER_BURST_WINDOWS["$user"]="$(append_reason "${USER_BURST_WINDOWS[$user]:-}" "${burst_window}|${burst_count}")"
        fi
    done < "$burst_summary_file"
}

estimate_user_ips() {
    local user_bracket="$1"
    local user="$2"
    local user_log="$TEMP_DIR/user_${user}_connections.log"
    local raw_ips_file="$TEMP_DIR/user_${user}_ips.txt"
    local counted_ips_file="$TEMP_DIR/user_${user}_ips_counted.txt"
    local conn_ids_file="$TEMP_DIR/user_${user}_conn_ids.txt"
    local user_line_nums_file="$TEMP_DIR/user_${user}_line_nums.txt"
    local ip_count
    local first_time

    : > "$raw_ips_file"
    USER_IP_METHOD["$user"]="neighbor-window"

    if [[ "$CONNECTION_ID_MODE" -eq 1 && -s "$CONN_IP_INDEX_FILE" ]]; then
        { grep -oP '\[\K[0-9]+(?= [0-9]+ms\])' "$user_log" || true; } | \
            awk -v limit="$IP_SAMPLE_SIZE" -v seed="$RANDOM" '
                BEGIN { srand(seed) }
                {
                    seen++
                    if (seen <= limit) {
                        sample[seen] = $0
                    } else {
                        slot = int(rand() * seen) + 1
                        if (slot <= limit) {
                            sample[slot] = $0
                        }
                    }
                }
                END {
                    count = (seen < limit) ? seen : limit
                    for (i = 1; i <= count; i++) {
                        print sample[i]
                    }
                }
            ' > "$conn_ids_file"

        awk 'NR==FNR {ip_by_conn[$1]=$2; next} ($1 in ip_by_conn) {print ip_by_conn[$1]}' "$CONN_IP_INDEX_FILE" "$conn_ids_file" > "$raw_ips_file" || true

        sort "$raw_ips_file" | uniq -c | sort -rn > "$counted_ips_file"
        ip_count="$(wc -l < "$counted_ips_file" | tr -d ' ')"

        if [[ "$ip_count" -gt 0 ]]; then
            USER_IP_COUNT["$user"]="$ip_count"
            USER_IP_METHOD["$user"]="connection-id"
            return 0
        fi

        : > "$raw_ips_file"
    fi

    { grep -n -F "$user_bracket" "$LOG_FILE" || true; } | \
        { grep -E "inbound (packet )?connection to" || true; } | \
        cut -d: -f1 | \
        awk -v limit="$IP_SAMPLE_SIZE" -v seed="$RANDOM" '
            BEGIN { srand(seed) }
            {
                seen++
                if (seen <= limit) {
                    sample[seen] = $0
                } else {
                    slot = int(rand() * seen) + 1
                    if (slot <= limit) {
                        sample[slot] = $0
                    }
                }
            }
            END {
                count = (seen < limit) ? seen : limit
                for (i = 1; i <= count; i++) {
                    print sample[i]
                }
            }
        ' | sort -n > "$user_line_nums_file"

    if [[ -s "$user_line_nums_file" && -s "$CONN_FROM_LINE_INDEX_FILE" ]]; then
        awk -v window=5 '
            NR == FNR {
                from_line[++from_count] = $1 + 0
                from_ip[from_count] = $2
                next
            }
            BEGIN {
                start = 1
            }
            {
                line_num = $1 + 0
                best_distance = window + 1
                best_ip = ""

                while (start <= from_count && from_line[start] < line_num - window) {
                    start++
                }

                for (i = start; i <= from_count && from_line[i] <= line_num + window; i++) {
                    distance = from_line[i] - line_num
                    if (distance < 0) distance = -distance
                    if (distance < best_distance) {
                        best_distance = distance
                        best_ip = from_ip[i]
                    }
                }
                if (best_ip != "") {
                    print best_ip
                }
            }
        ' "$CONN_FROM_LINE_INDEX_FILE" "$user_line_nums_file" > "$raw_ips_file"
    fi

    sort "$raw_ips_file" | uniq -c | sort -rn > "$counted_ips_file"
    ip_count="$(wc -l < "$counted_ips_file" | tr -d ' ')"

    if [[ "$ip_count" -eq 0 ]]; then
        first_time="$({ head -n 1 "$user_log" | grep -oP '^[+-][0-9]{4} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'; } || true)"
        if [[ -n "$first_time" ]]; then
            grep "$first_time" "$LOG_FILE" | \
                grep "inbound connection from" | \
                grep -oP 'connection from \K\[?[0-9A-Fa-f:.]+\]?(?=:[0-9]+)' | \
                tr -d '[]' | \
                sort | uniq -c | sort -rn > "$counted_ips_file" || true
            ip_count="$(wc -l < "$counted_ips_file" | tr -d ' ')"
        fi
    fi

    USER_IP_COUNT["$user"]="$ip_count"
}

detect_user_risk() {
    local user="$1"
    local targets_file="$TEMP_DIR/user_${user}_targets.txt"
    local total_conn="${USER_TOTAL_CONN[$user]:-0}"
    local ip_count="${USER_IP_COUNT[$user]:-0}"
    local active_hours="${USER_ACTIVE_HOURS[$user]:-0}"
    local conn_per_hour="${USER_CONN_PER_HOUR[$user]:-0}"
    local max_5min_conn="${USER_MAX_5MIN_CONN[$user]:-0}"
    local span_hours="${USER_SPAN_HOURS[$user]:-0.0}"
    local conn_rate_int
    local rate_risk_enabled
    local risk_score=0
    local risk_level
    local bt_count
    local commercial_tools
    local tool_name
    local tool_count
    local top_target_line
    local top_target_count=0
    local top_target_name=""
    local concentration
    local conc_int
    local top_target_risk_enabled
    local risk_reasons=""

    bt_count="$(
        { grep -iE "$BT_PATTERNS" "$targets_file" || true; } | awk '{sum+=$1} END {print sum+0}'
    )"
    USER_BT_COUNT["$user"]="$bt_count"

    if [[ "$bt_count" -gt 0 ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "🚨 **BT/PT下载**: ${bt_count}次")"
        risk_score=$((risk_score + RISK_BT))
    fi

    if [[ "$ip_count" -ge "$MULTI_IP_CRITICAL_THRESHOLD" ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "🚨 **多IP登录**: ${ip_count}个IP（严重超标）")"
        risk_score=$((risk_score + RISK_MULTI_IP_CRITICAL))
    elif [[ "$ip_count" -ge "$MULTI_IP_HIGH_THRESHOLD" ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "⚠️ **多IP登录**: ${ip_count}个IP（超标）")"
        risk_score=$((risk_score + RISK_MULTI_IP_HIGH))
    elif [[ "$ip_count" -ge "$MULTI_IP_WATCH_THRESHOLD" ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "🟡 **多IP登录**: ${ip_count}个IP（需关注）")"
        risk_score=$((risk_score + RISK_MULTI_IP_WATCH))
    fi

    commercial_tools="$({ grep -iE "$COMMERCIAL_PATTERNS" "$targets_file" || true; })"
    if [[ -n "$commercial_tools" ]]; then
        tool_name="$(printf '%s\n' "$commercial_tools" | head -n 1 | awk '{print $2}')"
        tool_count="$(printf '%s\n' "$commercial_tools" | awk '{sum+=$1} END {print sum+0}')"
        risk_reasons="$(append_reason "$risk_reasons" "⚠️ **商业工具**: ${tool_name} (${tool_count}次)")"
        risk_score=$((risk_score + RISK_COMMERCIAL))
    fi

    if [[ "$active_hours" -ge "$ACTIVE_ALL_DAY_THRESHOLD" ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "🟡 **全天活跃**: ${active_hours}/24小时")"
        risk_score=$((risk_score + RISK_ACTIVE_ALL_DAY))
    elif [[ "$active_hours" -ge "$ACTIVE_LONG_THRESHOLD" ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "🟡 **长时间活跃**: ${active_hours}/24小时")"
        risk_score=$((risk_score + RISK_ACTIVE_LONG))
    fi

    if [[ "$max_5min_conn" -ge "$BURST_5MIN_THRESHOLD" ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "🟡 **突发连接**: 5分钟内最高${max_5min_conn}次")"
        risk_score=$((risk_score + RISK_BURST))
    fi

    conn_rate_int="${conn_per_hour%%.*}"
    rate_risk_enabled="$(awk -v span="$span_hours" 'BEGIN {print (span >= 1.0) ? 1 : 0}')"
    if [[ "$rate_risk_enabled" -eq 1 && "$conn_rate_int" -ge "$CONN_PER_HOUR_THRESHOLD" ]]; then
        risk_reasons="$(append_reason "$risk_reasons" "🟡 **高连接速率**: ${conn_per_hour}次/小时")"
        risk_score=$((risk_score + RISK_HIGH_RATE))
    fi

    top_target_line="$(head -n 1 "$targets_file" || true)"
    if [[ -n "$top_target_line" ]]; then
        top_target_count="$(awk '{print $1}' <<< "$top_target_line")"
        top_target_name="$(awk '{print $2}' <<< "$top_target_line")"
    fi
    USER_TOP_TARGET["$user"]="$top_target_name"
    USER_TOP_TARGET_COUNT["$user"]="$top_target_count"

    if [[ "$total_conn" -gt 0 && "$top_target_count" -gt "$TOP_TARGET_MIN_COUNT" ]]; then
        concentration="$(awk "BEGIN {printf \"%.1f\", $top_target_count * 100.0 / $total_conn}")"
        conc_int="${concentration%%.*}"
        top_target_risk_enabled=0
        if [[ "$max_5min_conn" -ge "$BURST_5MIN_THRESHOLD" ]]; then
            top_target_risk_enabled=1
        elif [[ "$rate_risk_enabled" -eq 1 && "$conn_rate_int" -ge "$CONN_PER_HOUR_THRESHOLD" ]]; then
            top_target_risk_enabled=1
        fi

        if [[ "$conc_int" -gt "$TOP_TARGET_CONCENTRATION_THRESHOLD" && "$top_target_risk_enabled" -eq 1 ]]; then
            risk_reasons="$(append_reason "$risk_reasons" "🟡 **高频访问**: ${top_target_name} (${concentration}%)")"
            risk_score=$((risk_score + RISK_TOP_TARGET))
        fi
    fi

    if [[ "$risk_score" -ge 80 ]]; then
        risk_level="🔴 高风险"
        HIGH_RISK_COUNT=$((HIGH_RISK_COUNT + 1))
    elif [[ "$risk_score" -ge 30 ]]; then
        risk_level="🟡 中风险"
        MEDIUM_RISK_COUNT=$((MEDIUM_RISK_COUNT + 1))
    else
        risk_level="🟢 低风险"
        LOW_RISK_COUNT=$((LOW_RISK_COUNT + 1))
    fi

    USER_RISK_LEVEL["$user"]="$risk_level"
    USER_RISK_SCORE["$user"]="$risk_score"
    USER_RISK_REASONS["$user"]="$risk_reasons"
}

target_analysis_label() {
    local target="$1"

    if grep -qiE "$BT_LABEL_PATTERNS" <<< "$target"; then
        printf '🚨 BT/PT'
    elif grep -qiE "(adspower|multilogin)" <<< "$target"; then
        printf '⚠️ 商业工具'
    elif grep -qiE "(google|gstatic|googleapis|youtube)" <<< "$target"; then
        printf '✓ Google服务'
    elif grep -qiE "(cloudflare|akamai|cdn)" <<< "$target"; then
        printf '✓ CDN'
    elif grep -qiE "(microsoft|windows|office)" <<< "$target"; then
        printf '✓ 微软服务'
    elif grep -qiE "(apple|icloud)" <<< "$target"; then
        printf '✓ Apple服务'
    elif grep -qiE "(login|signin|auth|passport)" <<< "$target"; then
        printf '🔐 登录相关'
    elif grep -qiE "(api|webhook)" <<< "$target"; then
        printf '🔧 API接口'
    else
        printf '正常'
    fi
}

write_burst_user_log() {
    local user="$1"
    local max_5min_conn="${USER_MAX_5MIN_CONN[$user]:-0}"
    local user_log="$TEMP_DIR/user_${user}_connections.log"
    local output_file="$WARNINGS_DIR/${user}.log"
    local burst_windows="${USER_BURST_WINDOWS[$user]:-}"
    local burst_date
    local burst_time
    local burst_hour
    local burst_minute_start
    local burst_minute_end
    local burst_item
    local burst_window
    local burst_count
    local windows_file="$TEMP_DIR/user_${user}_warning_windows.tsv"

    if [[ "$max_5min_conn" -lt "$BURST_5MIN_THRESHOLD" ]]; then
        return 0
    fi

    if [[ -f "$user_log" ]]; then
        if [[ -n "$burst_windows" ]]; then
            : > "$windows_file"
            : > "$output_file"
            while IFS= read -r burst_item; do
                [[ -n "$burst_item" ]] || continue
                burst_window="${burst_item%|*}"
                burst_count="${burst_item##*|}"
                printf '%s\t%s\n' "$burst_window" "$burst_count" >> "$windows_file"
            done < <(tr "$REASON_SEP" '\n' <<< "$burst_windows")

            while IFS=$'\t' read -r burst_window burst_count; do
                [[ -n "${burst_window:-}" ]] || continue
                burst_date="${burst_window% *}"
                burst_time="${burst_window#* }"
                burst_hour=$((10#${burst_time%:*}))
                burst_minute_start=$((10#${burst_time#*:}))
                burst_minute_end=$((burst_minute_start + 4))

                {
                    printf '### %s (%s 次)\n' "$burst_window" "$burst_count"
                    printf '连接明细:\n'
                    awk -v date_key="$burst_date" -v hour="$burst_hour" -v min_start="$burst_minute_start" -v min_end="$burst_minute_end" '
                        {
                            if ($1 ~ /^[+-][0-9][0-9][0-9][0-9]$/ &&
                                $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ &&
                                $3 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) {
                                h = substr($3, 1, 2) + 0
                                m = substr($3, 4, 2) + 0
                                if ($2 == date_key && h == hour && m >= min_start && m <= min_end) {
                                    print
                                }
                            }
                        }
                    ' "$user_log"
                    printf '\n'
                } >> "$output_file"
            done < "$windows_file"
        else
            : > "$output_file"
        fi

        log_info "已导出5分钟连接异常窗口日志: ${output_file}"
    fi
}

write_user_markdown_detail() {
    local user_bracket="$1"
    local user="$2"
    local risk_score="${USER_RISK_SCORE[$user]:-0}"
    local risk_level="${USER_RISK_LEVEL[$user]:-🟢 低风险}"
    local total_conn="${USER_TOTAL_CONN[$user]:-0}"
    local ip_count="${USER_IP_COUNT[$user]:-0}"
    local target_count="${USER_TARGET_COUNT[$user]:-0}"
    local active_hours="${USER_ACTIVE_HOURS[$user]:-0}"
    local conn_per_hour="${USER_CONN_PER_HOUR[$user]:-0}"
    local max_5min_conn="${USER_MAX_5MIN_CONN[$user]:-0}"
    local ip_method="${USER_IP_METHOD[$user]:-unknown}"
    local span_hours="${USER_SPAN_HOURS[$user]:-0.0}"
    local first_seen="${USER_FIRST_SEEN[$user]:-未识别}"
    local last_seen="${USER_LAST_SEEN[$user]:-未识别}"
    local max_5min_window="${USER_MAX_5MIN_WINDOW[$user]:-未识别}"
    local span_text="未识别"
    local bt_count="${USER_BT_COUNT[$user]:-0}"
    local targets_file="$TEMP_DIR/user_${user}_targets.txt"
    local counted_ips_file="$TEMP_DIR/user_${user}_ips_counted.txt"
    local user_log="$TEMP_DIR/user_${user}_connections.log"
    local reasons="${USER_RISK_REASONS[$user]:-}"
    local total_ip_detections
    local count
    local ip
    local percentage
    local rank
    local target
    local analysis

    if [[ -n "$first_seen" && -n "$last_seen" && "$first_seen" != "未识别" && "$last_seen" != "未识别" ]]; then
        span_text="$(format_duration_from_seconds "$(awk -v h="$span_hours" 'BEGIN {printf "%d", h * 3600}')")"
    fi

    cat >> "$MD_OUTPUT" << EOF
## ${risk_level} **用户 ${user_bracket}**

### 📊 基本统计
- **连接总数**: $(printf "%'d" "$total_conn") 次
- **客户端IP数**: **${ip_count}个**
- **IP关联方式**: ${ip_method}
- **访问目标数**: ${target_count}个网站/服务
- **活跃时段**: ${active_hours}/24 小时
- **用户开始时间**: ${first_seen}
- **用户结束时间**: ${last_seen}
- **用户覆盖时长**: ${span_hours} 小时
- **用户覆盖时长(可读)**: ${span_text}
- **平均连接速率**: ${conn_per_hour} 次/小时
- **5分钟最高连接数**: ${max_5min_conn} 次
- **5分钟异常窗口**: ${max_5min_window}
- **风险评分**: ${risk_score}/200

### 🚨 滥用行为
EOF

    if [[ -n "$reasons" ]]; then
        while IFS= read -r reason; do
            [[ -n "$reason" ]] && printf -- '- %s\n' "$reason" >> "$MD_OUTPUT"
        done < <(tr "$REASON_SEP" '\n' <<< "$reasons")
    else
        printf -- '- 暂无明显滥用行为\n' >> "$MD_OUTPUT"
    fi
    printf '\n' >> "$MD_OUTPUT"

    if [[ "$bt_count" -gt 0 ]]; then
        cat >> "$MD_OUTPUT" << EOF
### 🚨 BT/PT下载详情
| 站点/Tracker | 访问次数 |
|-------------|---------|
EOF
        { grep -iE "$BT_PATTERNS" "$targets_file" || true; } | \
            awk -v limit="$TOP_N" 'NR <= limit {printf "| %s | %s |\n", $2, $1}' >> "$MD_OUTPUT"
        printf '\n' >> "$MD_OUTPUT"
    fi

    if [[ "$ip_count" -gt 0 ]]; then
        cat >> "$MD_OUTPUT" << EOF
### 📍 客户端IP完整列表
| IP地址 | 检测次数 | 占比 |
|--------|---------|------|
EOF
        total_ip_detections="$(awk '{sum+=$1} END {print sum+0}' "$counted_ips_file")"
        while IFS=' ' read -r count ip; do
            if [[ -n "${ip:-}" && "$total_ip_detections" -gt 0 ]]; then
                percentage="$(awk "BEGIN {printf \"%.1f\", $count * 100.0 / $total_ip_detections}")"
                printf '| %s | %s | %s%% |\n' "$ip" "$count" "$percentage" >> "$MD_OUTPUT"
            fi
        done < "$counted_ips_file"
        printf '\n' >> "$MD_OUTPUT"
    fi

    cat >> "$MD_OUTPUT" << EOF
### 🌐 访问目标 TOP ${TOP_N}
| 排名 | 网站/服务 | 访问次数 | 占比 | 分析 |
|-----|----------|---------|------|------|
EOF

    rank=0
    while IFS=' ' read -r count target; do
        [[ -n "${target:-}" ]] || continue
        rank=$((rank + 1))
        percentage="$(awk "BEGIN {printf \"%.1f\", $count * 100.0 / $total_conn}")"
        analysis="$(target_analysis_label "$target")"
        printf '| %s | %s | %s | %s%% | %s |\n' "$rank" "$target" "$count" "$percentage" "$analysis" >> "$MD_OUTPUT"
    done < <(sed -n "1,${TOP_N}p" "$targets_file")

    cat >> "$MD_OUTPUT" << EOF

### ⏰ 活跃时段分布
EOF

    awk '
        $1 ~ /^[+-][0-9][0-9][0-9][0-9]$/ &&
        $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ &&
        $3 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
            hour = substr($3, 1, 2) + 0
            count[hour]++
        }
        END {
            for (h in count) {
                printf "- **%02d:00-%02d:59**: %d 次连接\n", h, h, count[h]
            }
        }
    ' "$user_log" | sort -t: -k1 >> "$MD_OUTPUT"

    cat >> "$MD_OUTPUT" << EOF

---

EOF
}

analyze_all_users() {
    local user_index=0
    local user_bracket
    local user

    log_info "正在分析每个用户的详细行为..."

    while IFS= read -r user_bracket; do
        [[ -n "$user_bracket" ]] || continue
        user_index=$((user_index + 1))
        user="${user_bracket#\[}"
        user="${user%\]}"

        printf '  [%s/%s] 分析用户: %s\n' "$user_index" "$USER_COUNT" "$user_bracket"

        if ! extract_user_base_data "$user_bracket" "$user"; then
            log_info "跳过 ${user_bracket}: 未找到该标识对应的 inbound (packet) connection to 记录"
            USER_RISK_LEVEL["$user"]="⚪ 未分析"
            USER_RISK_SCORE["$user"]="0"
            USER_RISK_REASONS["$user"]="未找到连接记录"
            USER_TOTAL_CONN["$user"]="0"
            USER_IP_COUNT["$user"]="0"
            USER_TARGET_COUNT["$user"]="0"
            USER_ACTIVE_HOURS["$user"]="0"
            USER_CONN_PER_HOUR["$user"]="0"
            USER_MAX_5MIN_CONN["$user"]="0"
            USER_BURST_WINDOWS["$user"]=""
            USER_IP_METHOD["$user"]="none"
            USER_SPAN_HOURS["$user"]="0.0"
            USER_FIRST_SEEN["$user"]="未识别"
            USER_LAST_SEEN["$user"]="未识别"
            USER_MAX_5MIN_WINDOW["$user"]="未识别"
            USER_TOP_TARGET["$user"]=""
            USER_TOP_TARGET_COUNT["$user"]="0"
            USER_BT_COUNT["$user"]="0"
            SKIPPED_USER_COUNT=$((SKIPPED_USER_COUNT + 1))
            continue
        fi

        estimate_user_ips "$user_bracket" "$user"
        detect_user_risk "$user"
        write_burst_user_log "$user"
        write_user_markdown_detail "$user_bracket" "$user"
        ANALYZED_USER_COUNT=$((ANALYZED_USER_COUNT + 1))
    done < "$TEMP_DIR/users.txt"

    log_info "用户行为分析完成: 已分析 ${ANALYZED_USER_COUNT} 个，跳过 ${SKIPPED_USER_COUNT} 个"
    printf '\n'
}

write_summary_markdown() {
    local user_bracket
    local user
    local reasons
    local first_reason

    cat >> "$MD_OUTPUT" << EOF
## 📈 总体统计

### 风险分布
- 🔴 **高风险用户**: ${HIGH_RISK_COUNT} 个
- 🟡 **中风险用户**: ${MEDIUM_RISK_COUNT} 个
- 🟢 **低风险用户**: ${LOW_RISK_COUNT} 个
- ⚪ **未分析标识**: ${SKIPPED_USER_COUNT} 个

### 所有用户列表
| 用户ID | 风险等级 | 连接数 | 主要问题 |
|--------|---------|--------|---------|
EOF

    while IFS= read -r user_bracket; do
        [[ -n "$user_bracket" ]] || continue
        user="${user_bracket#\[}"
        user="${user%\]}"
        reasons="$(reasons_for_summary "${USER_RISK_REASONS[$user]:-无}")"
        first_reason="${reasons%%; *}"
        printf '| %s | %s | %s | %s |\n' \
            "$user_bracket" \
            "${USER_RISK_LEVEL[$user]:-🟢 低风险}" \
            "${USER_TOTAL_CONN[$user]:-0}" \
            "$first_reason" >> "$MD_OUTPUT"
    done < "$TEMP_DIR/users.txt"

    cat >> "$MD_OUTPUT" << EOF

---

## 💡 处理建议

### 🔴 高优先级（立即处理）
1. **BT/PT下载用户** - 立即警告并暂停服务
2. **多IP登录超过20个** - 确认是否转卖，考虑暂停
3. **商业大规模使用** - 联系用户确认用途，可能需要升级套餐

### 🟡 中优先级（3天内处理）
1. **多IP登录10-20个** - 发送警告邮件，持续观察
2. **24小时活跃** - 观察7天确认是否共享
3. **商业工具使用** - 确认是否个人合理使用

### 🟢 低优先级（持续监控）
1. **正常用户** - 建立行为基线，每周检查
2. **新增用户** - 首月重点观察

---

## 📊 数据说明

### 客户端IP统计方法
- 优先通过 sing-box 连接ID精确关联客户端IP
- 无连接ID或关联失败时，通过来源IP行号索引进行前后5行邻近窗口估算
- 默认随机采样每个用户 ${IP_SAMPLE_SIZE} 条连接记录，可用 --sample-size 调整
- IP数量为估算值，实际可能略有差异

### 风险评分规则
- BT/PT下载: +${RISK_BT}分
- 多IP登录${MULTI_IP_CRITICAL_THRESHOLD}+: +${RISK_MULTI_IP_CRITICAL}分
- 多IP登录${MULTI_IP_HIGH_THRESHOLD}-$((MULTI_IP_CRITICAL_THRESHOLD - 1)): +${RISK_MULTI_IP_HIGH}分
- 多IP登录${MULTI_IP_WATCH_THRESHOLD}-$((MULTI_IP_HIGH_THRESHOLD - 1)): +${RISK_MULTI_IP_WATCH}分
- 商业工具: +${RISK_COMMERCIAL}分
- 24小时活跃: +${RISK_ACTIVE_ALL_DAY}分
- 长时间活跃${ACTIVE_LONG_THRESHOLD}-$((ACTIVE_ALL_DAY_THRESHOLD - 1))小时: +${RISK_ACTIVE_LONG}分
- 高频单一目标: +${RISK_TOP_TARGET}分（需同时命中突发连接或高连接速率）
- 5分钟突发连接${BURST_5MIN_THRESHOLD}+: +${RISK_BURST}分
- 平均连接速率${CONN_PER_HOUR_THRESHOLD}+/小时: +${RISK_HIGH_RATE}分（用户覆盖时长至少1小时）

**风险等级**:
- 🔴 高风险: ≥80分
- 🟡 中风险: 30-79分
- 🟢 低风险: <30分

---

*报告生成时间: $(TZ="$LOG_DATE_TZ" date '+%Y-%m-%d %H:%M:%S')*
*脚本版本: v${SCRIPT_VERSION}*
EOF
}

print_done() {
    cat << EOF
==========================================
  ✅ 分析完成！
==========================================

📊 Markdown 报告: ${MD_OUTPUT}
EOF

    if [[ -n "$ARCHIVED_LOG" ]]; then
        printf '🗜️  日志归档: %s\n' "$ARCHIVED_LOG"
    fi
    if [[ -n "$ARCHIVED_WARNINGS_DIR" ]]; then
        printf '⚠️  异常窗口归档: %s\n' "$ARCHIVED_WARNINGS_DIR"
    fi

    cat << EOF

📈 统计摘要:
  - 🔴 高风险用户: ${HIGH_RISK_COUNT} 个
  - 🟡 中风险用户: ${MEDIUM_RISK_COUNT} 个
  - 🟢 低风险用户: ${LOW_RISK_COUNT} 个
EOF

    if [[ "$KEEP_TEMP" -eq 1 ]]; then
        printf '\n临时目录已保留: %s\n' "$TEMP_DIR"
    fi

    printf '\n建议优先查看高风险和中风险用户的详细信息\n\n'
}

main() {
    parse_args "$@"
    load_telegram_config
    check_dependencies
    init_runtime

    if [[ "$CLEANUP_MODE" -eq 1 ]]; then
        acquire_lock
        log_automation_event "[START] mode=cleanup dry_run=${CLEANUP_DRY_RUN}"
        cleanup_archives
        restart_sui_service_if_enabled
        log_automation_event "[DONE] mode=cleanup"
        return 0
    fi

    if [[ "$WEEKLY_SUMMARY_MODE" -eq 1 ]]; then
        acquire_lock
        log_automation_event "[START] mode=weekly-summary"
        send_weekly_summary
        log_automation_event "[DONE] mode=weekly-summary"
        return 0
    fi

    if is_window_mode; then
        acquire_lock
        SOURCE_LOG_FILE="$LOG_FILE"
        parse_date_window
        log_automation_event "[START] mode=window target_date=${TARGET_DATE} window=${ANALYSIS_WINDOW_LABEL}"
        slice_log_by_window "$SOURCE_LOG_FILE" "$SLICE_LOG_FILE"
        LOG_FILE="$SLICE_LOG_FILE"
    fi

    echo "=========================================="
    echo "  s-ui 日志滥用检测脚本 v${SCRIPT_VERSION}"
    echo "=========================================="
    echo ""
    echo "正在分析日志: ${LOG_FILE}"

    detect_log_capabilities
    build_conn_ip_index
    build_conn_from_line_index
    calculate_log_duration
    extract_users
    build_user_connection_logs
    init_reports
    analyze_all_users
    write_summary_markdown
    if is_window_mode; then
        archive_daily_outputs
        log_automation_event "[DONE] mode=window target_date=${TARGET_DATE} high=${HIGH_RISK_COUNT} medium=${MEDIUM_RISK_COUNT} low=${LOW_RISK_COUNT} skipped=${SKIPPED_USER_COUNT} report=${ARCHIVED_REPORT}"
    fi
    send_telegram_summary_if_enabled
    print_done
}

main "$@"

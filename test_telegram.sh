#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="$SCRIPT_DIR/telegram.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    printf '[ERROR] 找不到配置文件: %s\n' "$CONFIG_FILE" >&2
    printf '请先复制 telegram.conf.example 为 telegram.conf，并填写 bot token / chat id。\n' >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${TELEGRAM_ENABLED:=0}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${TELEGRAM_NODE_NAME:=}"
: "${TELEGRAM_SILENT:=0}"
: "${TELEGRAM_PARSE_MODE:=}"
: "${TELEGRAM_API_BASE:=https://api.telegram.org}"
: "${TELEGRAM_TIMEOUT:=15}"

if [[ "$TELEGRAM_ENABLED" -ne 1 ]]; then
    printf '[ERROR] TELEGRAM_ENABLED 不是 1，测试发送已停止。\n' >&2
    exit 1
fi

if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    printf '[ERROR] TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID 为空。\n' >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || {
    printf '[ERROR] 缺少 curl。\n' >&2
    exit 1
}

if [[ -z "$TELEGRAM_NODE_NAME" ]]; then
    TELEGRAM_NODE_NAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host')"
fi

message="s-ui audit Telegram test
Node: ${TELEGRAM_NODE_NAME}
Time: $(date '+%Y-%m-%d %H:%M:%S')

If you see this message, Telegram notification is configured correctly."

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

curl "${curl_args[@]}" >/dev/null
printf '[INFO] Telegram 测试消息发送成功。\n'

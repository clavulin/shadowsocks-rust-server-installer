#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/install.sh"

fail() {
  printf 'language regression failed: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local context="$3"

  [[ "${actual}" == "${expected}" ]] || \
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_equal 'zh' "$(default_language_for_timezone 'Asia/Shanghai')" \
  'Shanghai timezone should default to Chinese'
assert_equal 'zh' "$(default_language_for_timezone 'asia/shanghai')" \
  'timezone matching should be case-insensitive'
assert_equal 'zh' "$(default_language_for_timezone '/usr/share/zoneinfo/Asia/Shanghai')" \
  'zoneinfo path should default to Chinese'
assert_equal 'zh' "$(default_language_for_timezone 'PRC')" \
  'PRC timezone alias should default to Chinese'
assert_equal 'en' "$(default_language_for_timezone 'Asia/Hong_Kong')" \
  'non-Shanghai timezone should default to English'
assert_equal 'en' "$(default_language_for_timezone '')" \
  'unknown timezone should default to English'

assert_equal 'en' "$(normalize_language '1')" 'English menu number'
assert_equal 'en' "$(normalize_language 'ENGLISH')" 'English name'
assert_equal 'zh' "$(normalize_language '2')" 'Chinese menu number'
assert_equal 'zh' "$(normalize_language 'zh_CN')" 'Chinese locale name'
assert_equal 'zh' "$(normalize_language '中文')" 'Chinese native name'
if normalize_language 'de' >/dev/null 2>&1; then
  fail 'unsupported language should be rejected'
fi

SCRIPT_LANG='zh'
assert_equal '运行中' "$(status_value_label 'active')" \
  'active service state should be localized in Chinese'
assert_equal '已启用' "$(status_value_label 'enabled')" \
  'enabled service state should be localized in Chinese'
assert_equal '未知' "$(status_value_label 'unknown')" \
  'unknown service state should be localized in Chinese'
assert_equal '监听地址（IP 地址或网卡接口；按回车键监听所有接口） [::]：' \
  "$(listen_address_prompt '::')" \
  'Chinese listen address prompt'
assert_equal '监听地址（IP 地址或网卡接口；按回车键保留当前值） [192.0.2.10]：' \
  "$(listen_address_prompt '192.0.2.10')" \
  'Chinese listen address prompt with an existing custom value'
assert_equal '::' "$(prompt_listen_address '::' <<< '')" \
  'blank listen address should use the default'
assert_equal '192.0.2.10' "$(prompt_listen_address '192.0.2.10' <<< '')" \
  'blank listen address should preserve an existing custom value'
assert_equal 'eth0' "$(prompt_listen_address '::' <<< 'eth0')" \
  'custom network interface should be preserved'
SCRIPT_LANG='en'
assert_equal 'active' "$(status_value_label 'active')" \
  'English service state should remain unchanged'
assert_equal 'Listen address (IP address or network interface; press Enter for all interfaces) [::]:' \
  "$(listen_address_prompt '::')" \
  'English listen address prompt'
assert_equal 'Listen address (IP address or network interface; press Enter to keep the current value) [192.0.2.10]:' \
  "$(listen_address_prompt '192.0.2.10')" \
  'English listen address prompt with an existing custom value'
assert_equal 'n' "$(prompt_yes_no 'EOF default' 'n' </dev/null 2>/dev/null)" \
  'yes/no prompt should use the no default on end-of-input'
assert_equal 'y' "$(prompt_yes_no 'EOF default' 'y' </dev/null 2>/dev/null)" \
  'yes/no prompt should use the yes default on end-of-input'

SCRIPT_LANG='unset'
choose_language 'en' <<< $'\n' >/dev/null 2>&1
assert_equal 'en' "${SCRIPT_LANG}" 'blank selection should accept English default'

SCRIPT_LANG='unset'
choose_language 'zh' </dev/null >/dev/null 2>&1
assert_equal 'zh' "${SCRIPT_LANG}" 'end-of-input should accept Chinese default'

SCRIPT_LANG='unset'
choose_language 'en' <<< $'invalid\n2\n' >/dev/null 2>&1
assert_equal 'zh' "${SCRIPT_LANG}" 'invalid selection should retry'

detect_system_timezone() {
  printf '%s' 'Asia/Shanghai'
}

SCRIPT_LANG=''
initialize_language </dev/null >/dev/null 2>&1
assert_equal 'zh' "${SCRIPT_LANG}" 'Shanghai detection should flow into the default choice'

SCRIPT_LANG=''
initialize_language --lang English </dev/null >/dev/null 2>&1
assert_equal 'en' "${SCRIPT_LANG}" 'explicit language should override timezone default'

printf 'language regression passed\n'

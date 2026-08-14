#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"

cleanup_test() {
  if [[ -n "${TEST_TMP_DIR:-}" && -d "${TEST_TMP_DIR}" ]]; then
    rm -rf -- "${TEST_TMP_DIR}"
  fi
}
trap cleanup_test EXIT

# shellcheck source=/dev/null
source "${REPO_ROOT}/install.sh"

fail() {
  printf 'secret-output regression failed: %s\n' "$1" >&2
  exit 1
}

assert_masked() {
  local output="$1"
  local context="$2"

  [[ "${output}" == *'********'* ]] || \
    fail "${context}: masked marker missing"
  [[ "${output}" != *"${PASSWORD}"* ]] || \
    fail "${context}: plaintext password leaked"
  [[ "${output}" != *'ss://'* ]] || \
    fail "${context}: share link leaked"
}

CONFIG_DIR="${TEST_TMP_DIR}/etc/shadowsocks-rust"
CONFIG_PATH="${CONFIG_DIR}/config.json"
STATE_DIR="${TEST_TMP_DIR}/state"
CONFIG_NAME_PATH="${STATE_DIR}/node-name"
BIN_DIR="${TEST_TMP_DIR}/bin"
SERVICE_PATH="${TEST_TMP_DIR}/shadowsocks-rust.service"
mkdir -p "${CONFIG_DIR}" "${STATE_DIR}" "${BIN_DIR}"

cat >"${BIN_DIR}/ssserver" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${BIN_DIR}/ssservice" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${BIN_DIR}/ssserver" "${BIN_DIR}/ssservice"
: >"${SERVICE_PATH}"

PASSWORD='do-not-print-this-secret'
cat >"${CONFIG_PATH}" <<EOF
{
  "server": "::",
  "server_port": 8388,
  "password": "${PASSWORD}",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
printf '%s\n' 'secret test node' >"${CONFIG_NAME_PATH}"

# shellcheck disable=SC2034 # Used by sourced localization and summary helpers.
SCRIPT_LANG='en'
# shellcheck disable=SC2034 # Used by sourced print_summary.
INSTALL_VERSION='v-test'
# shellcheck disable=SC2034 # Used by sourced print_summary.
ASSET_NAME='test-asset.tar.xz'
# shellcheck disable=SC2034 # Used by sourced print_summary.
LISTEN_ADDRESS='::'
# shellcheck disable=SC2034 # Used by sourced print_summary and view_config_action.
SERVER_PORT='8388'
# shellcheck disable=SC2034 # Used by sourced print_summary and view_config_action.
METHOD='aes-256-gcm'
# shellcheck disable=SC2034 # Used by sourced print_summary.
MODE='tcp_and_udp'
# shellcheck disable=SC2034 # Used by sourced print_summary.
TIMEOUT_SECONDS='300'
# shellcheck disable=SC2034 # Used by sourced print_summary.
FIREWALL_MANAGER=''

detect_public_ip() {
  fail 'masked output must not perform public IP detection'
}

summary_output=$(print_summary </dev/null 2>&1)
assert_masked "${summary_output}" 'default install summary'

view_output=$(view_config_action </dev/null 2>&1)
assert_masked "${view_output}" 'default configuration view'

printf 'secret-output regression passed\n'

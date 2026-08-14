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
  printf 'config regression failed: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local context="$3"

  [[ "${actual}" == "${expected}" ]] || \
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_valid() {
  local path="$1"
  local context="$2"

  validate_server_config "${path}" >/dev/null 2>&1 || \
    fail "${context}: expected valid configuration"
}

assert_invalid() {
  local path="$1"
  local context="$2"

  if validate_server_config "${path}" >/dev/null 2>&1; then
    fail "${context}: expected invalid configuration"
  fi
}

command -v jq >/dev/null 2>&1 || fail 'jq is required for configuration tests'

CONFIG_DIR="${TEST_TMP_DIR}/etc/shadowsocks-rust"
CONFIG_PATH="${CONFIG_DIR}/config.json"
STATE_DIR="${TEST_TMP_DIR}/state"
CONFIG_NAME_PATH="${STATE_DIR}/node-name"
BIN_DIR="${TEST_TMP_DIR}/bin"
mkdir -p "${CONFIG_DIR}" "${STATE_DIR}" "${BIN_DIR}"

cat >"${CONFIG_PATH}" <<'EOF'
{
  "server": "::",
  "server_port": 8388,
  "password": "test password",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300,
  "plugin": "example-plugin",
  "plugin_opts": "mode=server;flag=yes",
  "future": {
    "enabled": true,
    "weights": [1, 2, 3]
  }
}
EOF

assert_valid "${CONFIG_PATH}" 'valid configuration with unknown fields'

printf '%s\n' 'edge node' >"${CONFIG_NAME_PATH}"
load_server_config "${CONFIG_PATH}" >/dev/null 2>&1
assert_equal '::' "${LISTEN_ADDRESS}" 'loaded server address'
assert_equal '8388' "${SERVER_PORT}" 'loaded server port'
assert_equal 'test password' "${PASSWORD}" 'loaded password'
assert_equal 'aes-256-gcm' "${METHOD}" 'loaded method'
assert_equal 'tcp_and_udp' "${MODE}" 'loaded mode'
assert_equal '300' "${TIMEOUT_SECONDS}" 'loaded timeout'
assert_equal 'edge node' "${CONFIG_NAME}" 'loaded node name'

jq '.server_port = "8388"' "${CONFIG_PATH}" >"${TEST_TMP_DIR}/invalid-port.json"
assert_invalid "${TEST_TMP_DIR}/invalid-port.json" 'string server port'

jq '.mode = "invalid"' "${CONFIG_PATH}" >"${TEST_TMP_DIR}/invalid-mode.json"
assert_invalid "${TEST_TMP_DIR}/invalid-mode.json" 'invalid traffic mode'

jq 'del(.password)' "${CONFIG_PATH}" >"${TEST_TMP_DIR}/missing-password.json"
assert_invalid "${TEST_TMP_DIR}/missing-password.json" 'missing required field'

ln -s "${CONFIG_PATH}" "${TEST_TMP_DIR}/config-link.json"
assert_invalid "${TEST_TMP_DIR}/config-link.json" 'symbolic link configuration'

cat >"${BIN_DIR}/ssservice" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${BIN_DIR}/ssservice"

# These stubs keep modify_config_action on its JSON-only path. They also turn
# accidental system or network access into a hard test failure.
require_installed() {
  :
}

require_jq() {
  :
}

chown() {
  :
}

systemctl() {
  if [[ "$#" -eq 2 && "$1" == 'is-active' && "$2" == "${SERVICE_NAME}" ]]; then
    printf '%s\n' 'inactive'
    return 1
  fi
  fail "unexpected systemctl call: $(printf '%q ' "$@")"
}

# shellcheck disable=SC2329 # Invoked indirectly by sourced modify_config_action.
detect_firewall_manager() {
  fail 'unchanged port should not trigger firewall detection'
}

detect_public_ip() {
  fail 'configuration update should not access the network'
}

view_config_action() {
  :
}

# shellcheck disable=SC2034 # Used by sourced localization helpers.
SCRIPT_LANG='en'
modify_config_action <<< $'127.0.0.1\n8388\naes-256-gcm\nudp_only\n600\nupdated node\nn\n' \
  >/dev/null 2>&1

assert_valid "${CONFIG_PATH}" 'updated configuration'
assert_equal '127.0.0.1' "$(jq -r '.server' "${CONFIG_PATH}")" \
  'updated server address'
assert_equal 'udp_only' "$(jq -r '.mode' "${CONFIG_PATH}")" \
  'updated traffic mode'
assert_equal '600' "$(jq -r '.timeout' "${CONFIG_PATH}")" \
  'updated timeout'
assert_equal 'test password' "$(jq -r '.password' "${CONFIG_PATH}")" \
  'unchanged password'
assert_equal 'example-plugin' "$(jq -r '.plugin' "${CONFIG_PATH}")" \
  'unknown plugin field preservation'
assert_equal 'mode=server;flag=yes' "$(jq -r '.plugin_opts' "${CONFIG_PATH}")" \
  'unknown plugin options preservation'
assert_equal '{"enabled":true,"weights":[1,2,3]}' \
  "$(jq -c '.future' "${CONFIG_PATH}")" \
  'unknown nested field preservation'
assert_equal 'updated node' "$(head -n1 "${CONFIG_NAME_PATH}")" \
  'updated node name'

backup_count=$(find "${CONFIG_DIR}" -maxdepth 1 -type f -name 'config.json.*.bak' | wc -l)
assert_equal '1' "${backup_count//[[:space:]]/}" 'configuration backup count'

# A new port is not committed until its requested firewall rules are ready.
# This keeps both the on-disk configuration and stopped service unchanged when
# firewall preparation fails.
detect_firewall_manager() {
  # shellcheck disable=SC2034 # Used by sourced modify_config_action.
  FIREWALL_MANAGER='ufw'
}

maybe_open_firewall() {
  return 1
}

config_sha_before=$(sha256sum "${CONFIG_PATH}")
config_sha_before=${config_sha_before%% *}
if modify_config_action <<< $'127.0.0.1\n9999\naes-256-gcm\nudp_only\n600\nupdated node\nn\ny\n' \
  >/dev/null 2>&1; then
  fail 'firewall preparation failure should abort configuration update'
fi
config_sha_after=$(sha256sum "${CONFIG_PATH}")
config_sha_after=${config_sha_after%% *}
assert_equal "${config_sha_before}" "${config_sha_after}" \
  'firewall-failed configuration SHA-256 preservation'
assert_equal '8388' "$(jq -r '.server_port' "${CONFIG_PATH}")" \
  'firewall-failed server port preservation'

backup_count=$(find "${CONFIG_DIR}" -maxdepth 1 -type f -name 'config.json.*.bak' | wc -l)
assert_equal '1' "${backup_count//[[:space:]]/}" \
  'firewall-failed configuration backup count'

printf 'config regression passed\n'

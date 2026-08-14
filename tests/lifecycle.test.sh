#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
SANDBOX_ROOT="${TEST_TMP_DIR}/root"
CALL_LOG="${TEST_TMP_DIR}/calls.log"

cleanup_test() {
  if [[ -n "${TEST_TMP_DIR:-}" && -d "${TEST_TMP_DIR}" ]]; then
    rm -rf -- "${TEST_TMP_DIR}"
  fi
}
trap cleanup_test EXIT

# shellcheck source=/dev/null
source "${REPO_ROOT}/install.sh"

fail() {
  printf 'lifecycle regression failed: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local context="$3"

  [[ "${actual}" == "${expected}" ]] || \
    fail "${context}: expected '${expected}', got '${actual}'"
}

assert_exists() {
  local path="$1"
  local context="$2"

  [[ -e "${path}" ]] || fail "${context}: expected ${path} to exist"
}

assert_not_exists() {
  local path="$1"
  local context="$2"

  [[ ! -e "${path}" ]] || fail "${context}: expected ${path} not to exist"
}

record_call() {
  local command_name="$1"
  local argument=""
  shift

  printf '%s' "${command_name}" >>"${CALL_LOG}"
  for argument in "$@"; do
    printf ' %s' "${argument}" >>"${CALL_LOG}"
  done
  printf '\n' >>"${CALL_LOG}"
}

reset_call_log() {
  : >"${CALL_LOG}"
}

read_call_log() {
  if [[ -s "${CALL_LOG}" ]]; then
    sed -n '1,$p' "${CALL_LOG}"
  fi
}

assert_no_host_side_effect_calls() {
  local context="$1"

  if grep -Eq '^(useradd|userdel|groupadd|groupdel|firewall-cmd|ufw|nft|iptables|ip6tables|curl|wget|apt-get|dnf|yum|zypper|pacman)( |$)' "${CALL_LOG}"; then
    fail "${context}: unexpected host-side call(s): $(read_call_log)"
  fi
}

# Redirect every installer-owned path before exercising lifecycle operations.
BIN_DIR="${SANDBOX_ROOT}/usr/local/bin"
CONFIG_DIR="${SANDBOX_ROOT}/etc/shadowsocks-rust"
CONFIG_PATH="${CONFIG_DIR}/config.json"
SERVICE_PATH="${SANDBOX_ROOT}/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="${SANDBOX_ROOT}/var/lib/shadowsocks-rust-installer"
USER_MARKER_PATH="${STATE_DIR}/service-user-created"
GROUP_MARKER_PATH="${STATE_DIR}/service-group-created"
FIREWALL_STATE_PATH="${STATE_DIR}/firewall-rule"
# shellcheck disable=SC2034 # Used by sourced lifecycle and localization helpers.
CONFIG_NAME_PATH="${STATE_DIR}/node-name"
# shellcheck disable=SC2034
SCRIPT_LANG='en'

write_test_binary() {
  local path="$1"
  local version="$2"

  cat >"${path}" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf '%s\\n' '${version}'
fi
exit 0
EOF
  chmod 0755 "${path}"
}

reset_fixture() {
  TMP_DIR=""
  rm -rf -- "${SANDBOX_ROOT}" "${TEST_TMP_DIR}/release"
  mkdir -p \
    "${BIN_DIR}" \
    "${CONFIG_DIR}" \
    "${SERVICE_PATH%/*}" \
    "${STATE_DIR}"

  write_test_binary "${BIN_DIR}/ssserver" 'old-ssserver'
  write_test_binary "${BIN_DIR}/ssservice" 'old-ssservice'

  cat >"${CONFIG_PATH}" <<'EOF'
{
  "server": "::",
  "server_port": 8388,
  "password": "preserve these exact bytes",
  "method": "aes-256-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300,
  "future_field": { "preserved": true }
}
EOF
  printf '%s\n' '[Unit]' 'Description=test fixture' >"${SERVICE_PATH}"
  printf '%s\n' 'state must remain unless configuration is removed' \
    >"${STATE_DIR}/preexisting-state"
  rm -f \
    "${USER_MARKER_PATH}" \
    "${GROUP_MARKER_PATH}" \
    "${FIREWALL_STATE_PATH}"
  SYSTEMCTL_ACTIVE_STATE='inactive'
  SYSTEMCTL_ENABLED_STATE='disabled'
  SYSTEMCTL_QUERY_RESULT=0
  SYSTEMCTL_DISABLE_RESULT=0
  SYSTEMCTL_RESTART_RESULT=0
  FIREWALLD_RULE_PRESENT='y'
  FIREWALLD_DEFAULT_ZONE='public'
  FIREWALLD_RULE_ZONE='public'
  FIREWALLD_RULE_PORT='23456'
  FIREWALLD_RULE_PROTOCOL='udp'
  FIREWALLD_REMOVE_RESULT=0
  FIREWALLD_RELOAD_RESULT=0
  UFW_RULE_PRESENT='y'
  UFW_ACTIVE_STATE='y'
  UFW_RULE_PORT='12345'
  UFW_RULE_PROTOCOL='tcp'
  UFW_STATUS_RESULT=0
  UFW_ALLOW_FAIL_PROTOCOL=''
  UFW_DELETE_RESULT=0
  USERDEL_RESULT=0
  GROUPDEL_RESULT=0
  reset_call_log
}

# Host-facing commands are always functions in this process. Even a regression
# that takes an unexpected branch therefore cannot touch systemd, identities,
# package managers, the network, or the host firewall.
SYSTEMCTL_ACTIVE_STATE='inactive'
SYSTEMCTL_ENABLED_STATE='disabled'
SYSTEMCTL_QUERY_RESULT=0
SYSTEMCTL_DISABLE_RESULT=0
SYSTEMCTL_RESTART_RESULT=0
systemctl() {
  record_call systemctl "$@"
  if [[ "$#" -eq 3 && "$1" == 'disable' && "$2" == '--now' && "$3" == "${SERVICE_NAME}" ]]; then
    if (( SYSTEMCTL_DISABLE_RESULT != 0 )); then
      return "${SYSTEMCTL_DISABLE_RESULT}"
    fi
    SYSTEMCTL_ACTIVE_STATE='inactive'
    SYSTEMCTL_ENABLED_STATE='disabled'
    return 0
  fi
  if [[ "$#" -eq 2 && "$1" == 'is-active' && "$2" == "${SERVICE_NAME}" ]]; then
    if (( SYSTEMCTL_QUERY_RESULT != 0 )); then
      return "${SYSTEMCTL_QUERY_RESULT}"
    fi
    printf '%s\n' "${SYSTEMCTL_ACTIVE_STATE}"
    [[ "${SYSTEMCTL_ACTIVE_STATE}" == 'active' ]]
    return
  fi
  if [[ "$#" -eq 2 && "$1" == 'is-enabled' && "$2" == "${SERVICE_NAME}" ]]; then
    if (( SYSTEMCTL_QUERY_RESULT != 0 )); then
      return "${SYSTEMCTL_QUERY_RESULT}"
    fi
    printf '%s\n' "${SYSTEMCTL_ENABLED_STATE}"
    [[ "${SYSTEMCTL_ENABLED_STATE}" == 'enabled' ]]
    return
  fi
  if [[ "$#" -eq 2 && "$1" == 'start' && "$2" == "${SERVICE_NAME}" ]]; then
    SYSTEMCTL_ACTIVE_STATE='active'
    return 0
  fi
  if [[ "$#" -eq 2 && "$1" == 'stop' && "$2" == "${SERVICE_NAME}" ]]; then
    SYSTEMCTL_ACTIVE_STATE='inactive'
    return 0
  fi
  if [[ "$#" -eq 2 && "$1" == 'restart' && "$2" == "${SERVICE_NAME}" ]]; then
    if (( SYSTEMCTL_RESTART_RESULT != 0 )); then
      return "${SYSTEMCTL_RESTART_RESULT}"
    fi
    SYSTEMCTL_ACTIVE_STATE='active'
    return 0
  fi
  return 0
}

journalctl() { record_call journalctl "$@"; return 0; }
id() { record_call id "$@"; return 0; }
getent() { record_call getent "$@"; return 0; }
useradd() { record_call useradd "$@"; return 0; }
USERDEL_RESULT=0
userdel() { record_call userdel "$@"; return "${USERDEL_RESULT}"; }
groupadd() { record_call groupadd "$@"; return 0; }
GROUPDEL_RESULT=0
groupdel() { record_call groupdel "$@"; return "${GROUPDEL_RESULT}"; }
FIREWALLD_RULE_PRESENT='y'
FIREWALLD_DEFAULT_ZONE='public'
FIREWALLD_RULE_ZONE='public'
FIREWALLD_RULE_PORT='23456'
FIREWALLD_RULE_PROTOCOL='udp'
FIREWALLD_REMOVE_RESULT=0
FIREWALLD_RELOAD_RESULT=0
firewall-cmd() {
  local zone=''
  local rule=''

  record_call firewall-cmd "$@"
  if [[ "$#" -eq 1 && "$1" == '--get-default-zone' ]]; then
    printf '%s\n' "${FIREWALLD_DEFAULT_ZONE}"
    return 0
  fi
  if [[ "$#" -eq 3 && "$1" == --zone=* && "$2" == '--permanent' && "$3" == --query-port=* ]]; then
    zone=${1#--zone=}
    rule=${3#--query-port=}
    [[ "${FIREWALLD_RULE_PRESENT}" == 'y' && "${zone}" == "${FIREWALLD_RULE_ZONE}" && "${rule}" == "${FIREWALLD_RULE_PORT}/${FIREWALLD_RULE_PROTOCOL}" ]]
    return
  fi
  if [[ "$#" -eq 3 && "$1" == --zone=* && "$2" == '--permanent' && "$3" == --add-port=* ]]; then
    FIREWALLD_RULE_ZONE=${1#--zone=}
    rule=${3#--add-port=}
    FIREWALLD_RULE_PORT=${rule%/*}
    FIREWALLD_RULE_PROTOCOL=${rule##*/}
    FIREWALLD_RULE_PRESENT='y'
    return 0
  fi
  if [[ "$#" -eq 3 && "$1" == --zone=* && "$2" == '--permanent' && "$3" == --remove-port=* ]]; then
    if (( FIREWALLD_REMOVE_RESULT != 0 )); then
      return "${FIREWALLD_REMOVE_RESULT}"
    fi
    zone=${1#--zone=}
    rule=${3#--remove-port=}
    if [[ "${zone}" != "${FIREWALLD_RULE_ZONE}" || "${rule}" != "${FIREWALLD_RULE_PORT}/${FIREWALLD_RULE_PROTOCOL}" ]]; then
      return 1
    fi
    FIREWALLD_RULE_PRESENT='n'
  fi
  if [[ "$#" -eq 1 && "$1" == '--reload' ]]; then
    return "${FIREWALLD_RELOAD_RESULT}"
  fi
  return 0
}
UFW_RULE_PRESENT='y'
UFW_ACTIVE_STATE='y'
UFW_RULE_PORT='12345'
UFW_RULE_PROTOCOL='tcp'
UFW_STATUS_RESULT=0
UFW_ALLOW_FAIL_PROTOCOL=''
UFW_DELETE_RESULT=0
ufw() {
  local rule=""

  record_call ufw "$@"
  if [[ "$#" -eq 1 && "$1" == 'status' ]]; then
    if (( UFW_STATUS_RESULT != 0 )); then
      return "${UFW_STATUS_RESULT}"
    fi
    if [[ "${UFW_ACTIVE_STATE}" == 'y' ]]; then
      printf '%s\n' 'Status: active'
    else
      printf '%s\n' 'Status: inactive'
      return 0
    fi
    if [[ "${UFW_RULE_PRESENT}" == 'y' ]]; then
      printf '%s/%s ALLOW Anywhere\n' "${UFW_RULE_PORT}" "${UFW_RULE_PROTOCOL}"
    fi
    return 0
  fi
  if [[ "$#" -eq 4 && "$1" == '--force' && "$2" == 'delete' && "$3" == 'allow' ]]; then
    if (( UFW_DELETE_RESULT != 0 )); then
      return "${UFW_DELETE_RESULT}"
    fi
    UFW_RULE_PRESENT='n'
    return 0
  fi
  if [[ "$#" -eq 2 && "$1" == 'allow' ]]; then
    rule="$2"
    if [[ "${rule##*/}" == "${UFW_ALLOW_FAIL_PROTOCOL}" ]]; then
      return 1
    fi
    UFW_RULE_PORT=${rule%/*}
    UFW_RULE_PROTOCOL=${rule##*/}
    UFW_RULE_PRESENT='y'
  fi
  return 0
}
nft() { record_call nft "$@"; return 0; }
iptables() { record_call iptables "$@"; return 0; }
ip6tables() { record_call ip6tables "$@"; return 0; }
curl() { record_call curl "$@"; return 97; }
wget() { record_call wget "$@"; return 97; }
apt-get() { record_call apt-get "$@"; return 97; }
dnf() { record_call dnf "$@"; return 97; }
yum() { record_call yum "$@"; return 97; }
zypper() { record_call zypper "$@"; return 97; }
pacman() { record_call pacman "$@"; return 97; }

reset_fixture

start_service_action >/dev/null
assert_equal $'systemctl start shadowsocks-rust\nsystemctl is-active shadowsocks-rust' "$(read_call_log)" \
  'start action systemctl dispatch'

reset_call_log
stop_service_action >/dev/null
assert_equal $'systemctl stop shadowsocks-rust\nsystemctl is-active shadowsocks-rust' "$(read_call_log)" \
  'stop action systemctl dispatch'

reset_call_log
restart_service_action >/dev/null
assert_equal $'systemctl restart shadowsocks-rust\nsystemctl is-active shadowsocks-rust' "$(read_call_log)" \
  'restart action systemctl dispatch'

# Keep update_action's orchestration intact while replacing every package and
# release-network boundary with a deterministic local fixture.
install_prerequisites() { :; }
prompt_default() { printf '%s' ''; }
fetch_release_metadata() {
  # shellcheck disable=SC2034 # Consumed by sourced update_action.
  INSTALL_VERSION='v-test-update'
}
choose_release_asset() {
  # shellcheck disable=SC2034 # Consumed by sourced update_action and download stub.
  ASSET_NAME='shadowsocks-v-test-update.x86_64-unknown-linux-gnu.tar.xz'
  # shellcheck disable=SC2034
  ASSET_URL='stub://release'
  # shellcheck disable=SC2034
  SHA256_URL='stub://release.sha256'
}
download_and_verify_release() {
  TMP_DIR="${TEST_TMP_DIR}/release"
  rm -rf -- "${TMP_DIR}"
  mkdir -p "${TMP_DIR}"
  write_test_binary "${TMP_DIR}/ssserver" 'new-ssserver'
  write_test_binary "${TMP_DIR}/ssservice" 'new-ssservice'
}

SYSTEMCTL_ACTIVE_STATE='inactive'
reset_call_log
config_sha_before=$(sha256sum "${CONFIG_PATH}")
config_sha_before=${config_sha_before%% *}
update_action >/dev/null
config_sha_after=$(sha256sum "${CONFIG_PATH}")
config_sha_after=${config_sha_after%% *}

assert_equal "${config_sha_before}" "${config_sha_after}" \
  'stopped-service update configuration SHA-256'
assert_equal 'systemctl is-active shadowsocks-rust' "$(read_call_log)" \
  'stopped-service update must only inspect active state'
assert_equal 'new-ssserver' "$("${BIN_DIR}/ssserver" --version)" \
  'stopped-service update binary replacement'
assert_no_host_side_effect_calls 'stopped-service update'

# An unavailable systemd control plane is not equivalent to a stopped service.
# No installed binary may be replaced while the active state is unknown.
reset_fixture
SYSTEMCTL_QUERY_RESULT=1
if update_action >/dev/null 2>&1; then
  fail 'systemd query failure should abort update'
fi
assert_equal 'old-ssserver' "$("${BIN_DIR}/ssserver" --version)" \
  'query-failed update ssserver preservation'
assert_equal 'old-ssservice' "$("${BIN_DIR}/ssservice" --version)" \
  'query-failed update ssservice preservation'
assert_equal 'systemctl is-active shadowsocks-rust' "$(read_call_log)" \
  'query-failed update systemctl dispatch'

# An active-service restart failure must restore both previous binaries.
reset_fixture
SYSTEMCTL_ACTIVE_STATE='active'
SYSTEMCTL_RESTART_RESULT=1
if update_action >/dev/null 2>&1; then
  fail 'active-service restart failure should fail update'
fi
assert_equal 'old-ssserver' "$("${BIN_DIR}/ssserver" --version)" \
  'restart-failed update ssserver rollback'
assert_equal 'old-ssservice' "$("${BIN_DIR}/ssservice" --version)" \
  'restart-failed update ssservice rollback'
assert_equal $'systemctl is-active shadowsocks-rust\nsystemctl restart shadowsocks-rust\nsystemctl restart shadowsocks-rust' \
  "$(read_call_log)" 'restart-failed update systemctl dispatch'

# The caller-supplied default for configuration removal must remain "no".
REMOVE_CONFIG_REPLY='default'
FIREWALL_CLEANUP_REPLY='n'
prompt_yes_no() {
  case "$1" in
    'Uninstall Shadowsocks-rust?')
      printf '%s' 'y'
      ;;
    'Also remove the configuration and its backups?')
      if [[ "${REMOVE_CONFIG_REPLY}" == 'default' ]]; then
        printf '%s' "$2"
      else
        printf '%s' "${REMOVE_CONFIG_REPLY}"
      fi
      ;;
    'Continue uninstalling the program and retain the firewall cleanup records?')
      printf '%s' "${FIREWALL_CLEANUP_REPLY}"
      ;;
    *)
      fail "unexpected yes/no prompt: $1"
      ;;
  esac
}

reset_fixture
REMOVE_CONFIG_REPLY='default'
uninstall_action >/dev/null
assert_exists "${CONFIG_PATH}" 'default uninstall configuration retention'
assert_exists "${STATE_DIR}/preexisting-state" 'default uninstall state retention'
assert_not_exists "${BIN_DIR}/ssserver" 'default uninstall ssserver removal'
assert_not_exists "${BIN_DIR}/ssservice" 'default uninstall ssservice removal'
assert_not_exists "${SERVICE_PATH}" 'default uninstall service-unit removal'
assert_equal $'systemctl disable --now shadowsocks-rust\nsystemctl is-active shadowsocks-rust\nsystemctl is-enabled shadowsocks-rust\nsystemctl daemon-reload\nsystemctl reset-failed shadowsocks-rust' \
  "$(read_call_log)" 'default uninstall systemctl dispatch'
assert_no_host_side_effect_calls 'default uninstall without ownership markers'

# Even when configuration deletion is explicitly requested, pre-existing
# identities without installer ownership markers must not be deleted.
reset_fixture
REMOVE_CONFIG_REPLY='y'
uninstall_action >/dev/null
assert_not_exists "${CONFIG_DIR}" 'explicit uninstall configuration removal'
assert_not_exists "${STATE_DIR}" 'explicit uninstall state removal'
assert_equal $'systemctl disable --now shadowsocks-rust\nsystemctl is-active shadowsocks-rust\nsystemctl is-enabled shadowsocks-rust\nsystemctl daemon-reload\nsystemctl reset-failed shadowsocks-rust' \
  "$(read_call_log)" 'explicit uninstall systemctl dispatch'
assert_no_host_side_effect_calls 'explicit uninstall without ownership markers'

# Failed owned-account deletion must retain its marker and report incomplete
# cleanup. A later uninstall retries the exact resource and releases state only
# after the account has actually been removed.
reset_fixture
printf '%s\n' 'created by installer' >"${USER_MARKER_PATH}"
printf '%s\n' 'created by installer' >"${GROUP_MARKER_PATH}"
REMOVE_CONFIG_REPLY='y'
USERDEL_RESULT=1
if uninstall_action >/dev/null 2>&1; then
  fail 'failed owned-user deletion should report incomplete uninstall cleanup'
fi
assert_not_exists "${CONFIG_DIR}" \
  'account-cleanup failure configuration removal'
assert_exists "${USER_MARKER_PATH}" \
  'failed owned-user deletion marker retention'
assert_not_exists "${GROUP_MARKER_PATH}" \
  'successful owned-group deletion marker release'
assert_exists "${STATE_DIR}" \
  'account-cleanup failure state retention'

USERDEL_RESULT=0
reset_call_log
uninstall_action >/dev/null
assert_not_exists "${STATE_DIR}" \
  'successful owned-user cleanup state release'
assert_equal $'systemctl disable --now shadowsocks-rust\nsystemctl is-active shadowsocks-rust\nsystemctl is-enabled shadowsocks-rust\nsystemctl daemon-reload\nsystemctl reset-failed shadowsocks-rust\nid -u shadowsocks\nuserdel shadowsocks' \
  "$(read_call_log)" 'owned-user cleanup retry dispatch'

# A missing unit file does not prove that systemd has unloaded the service.
# Uninstall must query and stop the service by name before deleting binaries.
reset_fixture
rm -f "${SERVICE_PATH}"
SYSTEMCTL_ACTIVE_STATE='active'
SYSTEMCTL_ENABLED_STATE='enabled'
SYSTEMCTL_DISABLE_RESULT=0
REMOVE_CONFIG_REPLY='default'
uninstall_action >/dev/null
assert_not_exists "${BIN_DIR}/ssserver" \
  'uninstall with missing unit must stop service before binary removal'
assert_equal $'systemctl disable --now shadowsocks-rust\nsystemctl is-active shadowsocks-rust\nsystemctl is-enabled shadowsocks-rust\nsystemctl daemon-reload\nsystemctl reset-failed shadowsocks-rust' \
  "$(read_call_log)" 'missing-unit uninstall systemctl dispatch'

# If systemd still reports the service active after a stop failure, no
# installer-owned file may be removed.
reset_fixture
rm -f "${SERVICE_PATH}"
SYSTEMCTL_ACTIVE_STATE='active'
SYSTEMCTL_ENABLED_STATE='enabled'
SYSTEMCTL_DISABLE_RESULT=1
REMOVE_CONFIG_REPLY='default'
if uninstall_action >/dev/null 2>&1; then
  fail 'active service stop failure should abort uninstall'
fi
assert_exists "${BIN_DIR}/ssserver" \
  'failed service stop must preserve ssserver'
assert_exists "${BIN_DIR}/ssservice" \
  'failed service stop must preserve ssservice'
assert_equal $'systemctl disable --now shadowsocks-rust\nsystemctl is-active shadowsocks-rust\nsystemctl is-enabled shadowsocks-rust' \
  "$(read_call_log)" 'failed-stop uninstall systemctl dispatch'
SYSTEMCTL_ACTIVE_STATE='inactive'
SYSTEMCTL_ENABLED_STATE='disabled'
SYSTEMCTL_DISABLE_RESULT=0

# If systemd returns no recognizable state, uninstall must preserve every file.
reset_fixture
SYSTEMCTL_DISABLE_RESULT=1
SYSTEMCTL_QUERY_RESULT=1
if uninstall_action >/dev/null 2>&1; then
  fail 'systemd query failure should abort uninstall'
fi
assert_exists "${BIN_DIR}/ssserver" \
  'query-failed uninstall ssserver preservation'
assert_exists "${SERVICE_PATH}" \
  'query-failed uninstall service-unit preservation'
assert_equal $'systemctl disable --now shadowsocks-rust\nsystemctl is-active shadowsocks-rust' \
  "$(read_call_log)" 'query-failed uninstall systemctl dispatch'

# Service-unit replacement must never follow a symbolic link. A regular unit
# is written through a same-directory temporary file and receives one backup.
reset_fixture
unit_target="${TEST_TMP_DIR}/outside-unit-target"
printf '%s\n' 'must not change' >"${unit_target}"
rm -f "${SERVICE_PATH}"
ln -s "${unit_target}" "${SERVICE_PATH}"
if write_systemd_unit >/dev/null 2>&1; then
  fail 'symbolic-link service unit should be rejected'
fi
assert_equal 'must not change' "$(head -n1 "${unit_target}")" \
  'symbolic-link target preservation'
[[ -L "${SERVICE_PATH}" ]] || fail 'rejected service-unit link should remain a link'

reset_fixture
write_systemd_unit >/dev/null
[[ ! -L "${SERVICE_PATH}" ]] || fail 'written service unit must be a regular file'
grep -Fq 'ExecStart=' "${SERVICE_PATH}" || \
  fail 'written service unit is missing ExecStart'
unit_backup_count=$(find "${SERVICE_PATH%/*}" -maxdepth 1 -type f \
  -name "${SERVICE_NAME}.service.*.bak" | wc -l)
assert_equal '1' "${unit_backup_count//[[:space:]]/}" \
  'service-unit backup count'

# Only valid, precisely recorded ownership entries may result in firewall
# deletion calls. Firewalld records require an explicit zone; legacy zone-less,
# unknown, and damaged records are preserved verbatim and fail closed.
reset_fixture
cat >"${FIREWALL_STATE_PATH}" <<'EOF'
ufw|12345|tcp
firewalld|23456|udp
ufw|12345|icmp
ufw|0|tcp
ufw|65536|udp
ufw|not-a-port|tcp
unknown|34567|tcp
ufw|45678|tcp|surplus
EOF
reset_call_log
if remove_recorded_firewall_rule; then
  fail 'unknown firewall ownership records should fail cleanup'
fi

assert_equal $'ufw status\nufw status\nufw --force delete allow 12345/tcp\nufw status' \
  "$(read_call_log)" 'owned firewall rule parsing'
assert_equal $'firewalld|23456|udp\nufw|12345|icmp\nufw|0|tcp\nufw|65536|udp\nufw|not-a-port|tcp\nunknown|34567|tcp\nufw|45678|tcp|surplus' \
  "$(sed -n '1,$p' "${FIREWALL_STATE_PATH}")" \
  'unknown firewall ownership state preservation'

# A pending record is persisted before a rule is added and promoted only after
# success. If the second UFW rule fails, TCP is owned and UDP remains pending.
reset_fixture
UFW_RULE_PRESENT='n'
UFW_ALLOW_FAIL_PROTOCOL='udp'
# shellcheck disable=SC2034 # Used by sourced maybe_open_firewall.
FIREWALL_MANAGER='ufw'
# shellcheck disable=SC2034 # Used by sourced maybe_open_firewall.
SERVER_PORT='33333'
# shellcheck disable=SC2034 # Used by sourced maybe_open_firewall.
OPEN_FIREWALL='y'
if maybe_open_firewall >/dev/null 2>&1; then
  fail 'partial UFW add failure should fail firewall setup'
fi
assert_equal $'ufw|33333|tcp|owned\nufw|33333|udp|pending' \
  "$(sed -n '1,$p' "${FIREWALL_STATE_PATH}")" \
  'partial UFW add ownership persistence'

# New firewalld ownership records bind each rule to the zone used for its add,
# so cleanup remains correct if the host's default zone changes later.
reset_fixture
FIREWALLD_RULE_PRESENT='n'
FIREWALLD_DEFAULT_ZONE='public'
# shellcheck disable=SC2034 # Used by sourced maybe_open_firewall.
FIREWALL_MANAGER='firewalld'
# shellcheck disable=SC2034 # Used by sourced maybe_open_firewall.
SERVER_PORT='33333'
# shellcheck disable=SC2034 # Used by sourced maybe_open_firewall.
OPEN_FIREWALL='y'
maybe_open_firewall >/dev/null
assert_equal $'firewalld|33333|tcp|owned|public\nfirewalld|33333|udp|owned|public' \
  "$(sed -n '1,$p' "${FIREWALL_STATE_PATH}")" \
  'firewalld zone ownership persistence'
assert_equal $'firewall-cmd --get-default-zone\nfirewall-cmd --zone=public --permanent --query-port=33333/tcp\nfirewall-cmd --zone=public --permanent --add-port=33333/tcp\nfirewall-cmd --zone=public --permanent --query-port=33333/udp\nfirewall-cmd --zone=public --permanent --add-port=33333/udp\nfirewall-cmd --reload' \
  "$(read_call_log)" 'firewalld explicit-zone add dispatch'

# Pending means the installer has not proved ownership. Cleanup only queries:
# a present rule is preserved, while an absent rule lets the record converge.
reset_fixture
printf '%s\n' 'ufw|12345|tcp|pending' >"${FIREWALL_STATE_PATH}"
reset_call_log
if remove_recorded_firewall_rule; then
  fail 'pending firewall state should require explicit retention confirmation'
fi
assert_equal 'ufw status' "$(read_call_log)" \
  'pending firewall cleanup should only query a present rule'
assert_equal 'ufw|12345|tcp|pending' "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'pending firewall state preservation'

UFW_RULE_PRESENT='n'
reset_call_log
remove_recorded_firewall_rule
assert_equal 'ufw status' "$(read_call_log)" \
  'pending firewall retry should only query rule state'
assert_not_exists "${FIREWALL_STATE_PATH}" \
  'absent pending firewall state convergence'

reset_fixture
printf '%s\n' 'firewalld|23456|udp|pending|public' >"${FIREWALL_STATE_PATH}"
FIREWALLD_RULE_PRESENT='n'
reset_call_log
remove_recorded_firewall_rule
assert_equal 'firewall-cmd --zone=public --permanent --query-port=23456/udp' \
  "$(read_call_log)" 'pending firewalld retry should only query rule state'
assert_not_exists "${FIREWALL_STATE_PATH}" \
  'absent pending firewalld state convergence'

# A firewalld permanent deletion can succeed while its reload fails. The next
# cleanup must retry that reload even though the permanent rule is then absent,
# and may release ownership only after the runtime ruleset has been refreshed.
reset_fixture
printf '%s\n' 'firewalld|23456|udp|owned|public' >"${FIREWALL_STATE_PATH}"
FIREWALLD_DEFAULT_ZONE='drop'
FIREWALLD_RELOAD_RESULT=1
reset_call_log
if remove_recorded_firewall_rule >/dev/null 2>&1; then
  fail 'failed firewalld reload should report cleanup failure'
fi
assert_equal $'firewall-cmd --zone=public --permanent --query-port=23456/udp\nfirewall-cmd --zone=public --permanent --query-port=23456/udp\nfirewall-cmd --zone=public --permanent --remove-port=23456/udp\nfirewall-cmd --reload' \
  "$(read_call_log)" 'first firewalld cleanup attempt'
assert_equal 'firewalld|23456|udp|deleting|public' \
  "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'failed firewalld reload ownership retention'

FIREWALLD_RELOAD_RESULT=0
reset_call_log
remove_recorded_firewall_rule >/dev/null
assert_equal $'firewall-cmd --zone=public --permanent --query-port=23456/udp\nfirewall-cmd --reload' \
  "$(read_call_log)" 'firewalld reload retry after permanent deletion'
assert_not_exists "${FIREWALL_STATE_PATH}" \
  'successful firewalld reload ownership release'

# A failed deletion must retain the exact ownership entry for a later retry.
reset_fixture
printf '%s\n' 'ufw|12345|tcp' >"${FIREWALL_STATE_PATH}"
UFW_DELETE_RESULT=1
if remove_recorded_firewall_rule >/dev/null 2>&1; then
  fail 'failed UFW deletion should report failure'
fi
assert_equal 'ufw|12345|tcp|deleting' "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'failed UFW deletion ownership retention'

# Inactive UFW hides persistent rules from `ufw status`. Treat that as an
# unverifiable state: retain ownership and never issue a delete based on an
# apparent absence that would reappear when UFW is enabled again.
reset_fixture
printf '%s\n' 'ufw|12345|tcp|owned' >"${FIREWALL_STATE_PATH}"
UFW_ACTIVE_STATE='n'
reset_call_log
if remove_recorded_firewall_rule >/dev/null 2>&1; then
  fail 'inactive UFW should fail owned-rule cleanup safely'
fi
assert_equal 'ufw status' "$(read_call_log)" \
  'inactive UFW cleanup must only inspect status'
assert_equal 'ufw|12345|tcp|owned' "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'inactive UFW ownership-state preservation'

# Firewall cleanup failure defaults to preserving program files. An explicit
# second confirmation allows program removal while retaining exact ownership
# state for a later cleanup retry.
reset_fixture
printf '%s\n' 'ufw|12345|tcp|owned' >"${FIREWALL_STATE_PATH}"
UFW_DELETE_RESULT=1
FIREWALL_CLEANUP_REPLY='n'
if uninstall_action >/dev/null 2>&1; then
  fail 'firewall cleanup refusal should abort uninstall'
fi
assert_exists "${BIN_DIR}/ssserver" \
  'firewall cleanup refusal ssserver preservation'
assert_exists "${SERVICE_PATH}" \
  'firewall cleanup refusal service-unit preservation'
assert_exists "${FIREWALL_STATE_PATH}" \
  'firewall cleanup refusal ownership-state preservation'

reset_fixture
printf '%s\n' 'ufw|12345|tcp|owned' >"${FIREWALL_STATE_PATH}"
UFW_DELETE_RESULT=1
FIREWALL_CLEANUP_REPLY='y'
uninstall_action >/dev/null
assert_not_exists "${BIN_DIR}/ssserver" \
  'confirmed firewall cleanup bypass ssserver removal'
assert_not_exists "${SERVICE_PATH}" \
  'confirmed firewall cleanup bypass service-unit removal'
assert_exists "${FIREWALL_STATE_PATH}" \
  'confirmed firewall cleanup bypass ownership-state retention'

# State rewrites must preserve the original bytes if their same-directory
# temporary file cannot be created. Both bulk cleanup and targeted record
# removal are called from conditional contexts where Bash suppresses errexit.
REAL_MKTEMP_PATH=$(type -P mktemp)
FAIL_FIREWALL_MKTEMP='n'
# shellcheck disable=SC2329 # Invoked indirectly by sourced state helpers.
mktemp() {
  if [[ "${FAIL_FIREWALL_MKTEMP}" == 'y' && "${1:-}" == "${STATE_DIR}/.firewall-rule.XXXXXX" ]]; then
    return 1
  fi
  "${REAL_MKTEMP_PATH}" "$@"
}

reset_fixture
printf '%s\n' 'ufw|12345|tcp|owned' >"${FIREWALL_STATE_PATH}"
firewall_state_sha_before=$(sha256sum "${FIREWALL_STATE_PATH}")
firewall_state_sha_before=${firewall_state_sha_before%% *}
FAIL_FIREWALL_MKTEMP='y'
if remove_recorded_firewall_rule >/dev/null 2>&1; then
  fail 'mktemp failure should fail recorded firewall cleanup'
fi
firewall_state_sha_after=$(sha256sum "${FIREWALL_STATE_PATH}")
firewall_state_sha_after=${firewall_state_sha_after%% *}
assert_equal "${firewall_state_sha_before}" "${firewall_state_sha_after}" \
  'mktemp-failed bulk firewall state preservation'

if discard_firewall_rule_record ufw 12345 tcp owned >/dev/null 2>&1; then
  fail 'mktemp failure should fail targeted firewall record removal'
fi
firewall_state_sha_after=$(sha256sum "${FIREWALL_STATE_PATH}")
firewall_state_sha_after=${firewall_state_sha_after%% *}
assert_equal "${firewall_state_sha_before}" "${firewall_state_sha_after}" \
  'mktemp-failed targeted firewall state preservation'
FAIL_FIREWALL_MKTEMP='n'

# If the rule add succeeds, ownership promotion fails, and compensating delete
# also fails, the transaction remains ambiguous. A present rule must never be
# deleted on retry; only observed absence may release the deleting record.
reset_fixture
UFW_RULE_PRESENT='n'
UFW_DELETE_RESULT=1
REAL_MV_PATH=$(type -P mv)
FIREWALL_STATE_MV_COUNT=0
FIREWALL_STATE_MV_FAIL_ON=2
# shellcheck disable=SC2329 # Invoked indirectly by sourced state helpers.
mv() {
  local arguments=("$@")
  local destination="${arguments[${#arguments[@]}-1]}"

  if [[ "${destination}" == "${FIREWALL_STATE_PATH}" ]]; then
    FIREWALL_STATE_MV_COUNT=$((FIREWALL_STATE_MV_COUNT + 1))
    if (( FIREWALL_STATE_MV_COUNT == FIREWALL_STATE_MV_FAIL_ON )); then
      return 1
    fi
  fi
  "${REAL_MV_PATH}" "$@"
}

if open_firewall_rule ufw 33333 tcp >/dev/null 2>&1; then
  fail 'ownership promotion plus compensation failure should fail rule setup'
fi
assert_equal 'y' "${FIREWALL_RULE_CHANGED}" \
  'successful rule add transaction marker'
assert_equal 'ufw|33333|tcp|deleting' \
  "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'ambiguous firewall deletion persistence'

FIREWALL_STATE_MV_FAIL_ON=0
UFW_DELETE_RESULT=0
reset_call_log
if remove_recorded_firewall_rule >/dev/null 2>&1; then
  fail 'ambiguous present rule should fail closed without a second deletion'
fi
assert_equal 'ufw status' "$(read_call_log)" \
  'ambiguous present rule retry must only inspect status'
assert_equal 'ufw|33333|tcp|deleting' \
  "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'ambiguous present rule state retention'

UFW_RULE_PRESENT='n'
remove_recorded_firewall_rule >/dev/null
assert_not_exists "${FIREWALL_STATE_PATH}" \
  'ambiguous absent rule state convergence'

# If external deletion succeeds but committing the ownership removal fails,
# deleting remains durable. A user-created replacement rule is then preserved;
# state converges only after that replacement is independently absent.
reset_fixture
printf '%s\n' 'ufw|12345|tcp|owned' >"${FIREWALL_STATE_PATH}"
FIREWALL_STATE_MV_COUNT=0
FIREWALL_STATE_MV_FAIL_ON=2
if delete_managed_firewall_rule ufw 12345 tcp >/dev/null 2>&1; then
  fail 'ownership commit failure should fail managed firewall deletion'
fi
assert_equal 'n' "${UFW_RULE_PRESENT}" \
  'external firewall deletion before ownership commit failure'
assert_equal 'ufw|12345|tcp|deleting' \
  "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'ownership commit failure deleting-state retention'

FIREWALL_STATE_MV_FAIL_ON=0
UFW_RULE_PRESENT='y'
reset_call_log
if remove_recorded_firewall_rule >/dev/null 2>&1; then
  fail 'recreated ambiguous rule should require manual resolution'
fi
assert_equal 'ufw status' "$(read_call_log)" \
  'recreated ambiguous rule must not be deleted'
assert_equal 'y' "${UFW_RULE_PRESENT}" \
  'recreated ambiguous firewall rule preservation'
assert_equal 'ufw|12345|tcp|deleting' \
  "$(head -n1 "${FIREWALL_STATE_PATH}")" \
  'recreated ambiguous rule state retention'

UFW_RULE_PRESENT='n'
remove_recorded_firewall_rule >/dev/null
assert_not_exists "${FIREWALL_STATE_PATH}" \
  'manually resolved ambiguous rule convergence'

printf 'lifecycle regression passed\n'

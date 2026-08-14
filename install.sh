#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
REPO_API_BASE="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_PATH="${CONFIG_DIR}/config.json"
SERVICE_NAME="shadowsocks-rust"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="shadowsocks"
STATE_DIR="/var/lib/shadowsocks-rust-installer"
USER_MARKER_PATH="${STATE_DIR}/service-user-created"
GROUP_MARKER_PATH="${STATE_DIR}/service-group-created"
FIREWALL_STATE_PATH="${STATE_DIR}/firewall-rule"
CONFIG_NAME_PATH="${STATE_DIR}/node-name"
DEFAULT_BIND_ADDRESS="::"
DEFAULT_PORT="8388"
DEFAULT_METHOD="2022-blake3-aes-128-gcm"
DEFAULT_MODE="tcp_and_udp"
DEFAULT_TIMEOUT="300"
TMP_DIR=""
SCRIPT_LANG="${SSR_INSTALLER_LANG:-}"
COMMON_METHODS=(
  "${DEFAULT_METHOD}|Recommended default. AEAD 2022 with AES-128-GCM.|推荐默认值，使用 AES-128-GCM 的 AEAD 2022。"
  "2022-blake3-aes-256-gcm|AEAD 2022 with AES-256-GCM.|使用 AES-256-GCM 的 AEAD 2022。"
  "2022-blake3-chacha20-poly1305|AEAD 2022 for hosts or clients that prefer ChaCha20.|适合优先使用 ChaCha20 的主机或客户端。"
  "chacha20-ietf-poly1305|Widely compatible classic AEAD cipher.|兼容性广泛的经典 AEAD 加密方法。"
  "aes-128-gcm|Widely compatible classic AEAD cipher.|兼容性广泛的经典 AEAD 加密方法。"
  "aes-256-gcm|Widely compatible classic AEAD cipher.|兼容性广泛的经典 AEAD 加密方法。"
)

VERSION_INPUT=""
INSTALL_VERSION=""
RELEASE_JSON=""
ASSET_URL=""
ASSET_NAME=""
SHA256_URL=""
LISTEN_ADDRESS=""
SERVER_PORT=""
METHOD=""
PASSWORD=""
MODE=""
TIMEOUT_SECONDS=""
CONFIG_NAME=""
OPEN_FIREWALL=""
FIREWALL_MANAGER=""
FIREWALL_TCP_CHANGED="n"
FIREWALL_UDP_CHANGED="n"
FIREWALLD_ZONE=""

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

on_error() {
  local exit_code=$?
  log_error "$(l10n "Operation failed at line ${BASH_LINENO[0]} (exit ${exit_code})." "操作在第 ${BASH_LINENO[0]} 行失败（退出码 ${exit_code}）。")"
  exit "${exit_code}"
}

restore_error_trap() {
  trap on_error ERR
}

main() {
  initialize_language "$@"
  require_root
  require_systemd
  main_menu
}

install_action() {
  if is_installed; then
    log_info "$(l10n "Shadowsocks-rust is already installed. Use Update or Modify configuration instead." "Shadowsocks-rust 已安装，请使用更新或修改配置信息功能。")"
    return 0
  fi

  if has_program_artifacts; then
    log_error "$(l10n "A partial Shadowsocks-rust installation was found. Uninstall it before installing again." "检测到不完整的 Shadowsocks-rust 安装，请先卸载后再安装。")"
    return 1
  fi

  install_prerequisites
  detect_firewall_manager
  collect_inputs
  fetch_release_metadata
  choose_release_asset
  download_and_verify_release
  install_binaries
  ensure_supported_method
  ensure_service_account
  write_server_config
  write_systemd_unit
  maybe_open_firewall
  enable_and_restart_service
  print_summary
}

require_installed() {
  if ! is_installed; then
    log_error "$(l10n "Shadowsocks-rust is not fully installed. Run the install action first." "Shadowsocks-rust 尚未完整安装，请先执行安装。")"
    return 1
  fi
}

update_action() {
  local current_method=""
  local was_active="n"
  local old_ssserver=""
  local old_ssservice=""
  local new_ssserver=""
  local new_ssservice=""
  local staged_ssserver=""
  local staged_ssservice=""

  require_installed
  install_prerequisites
  validate_server_config "${CONFIG_PATH}"

  VERSION_INPUT=$(prompt_default "$(l10n "Version to install (blank = latest stable release)" "要安装的版本（留空 = 最新稳定版）")" "")
  fetch_release_metadata
  choose_release_asset
  download_and_verify_release

  new_ssserver=$(find_release_binary ssserver)
  new_ssservice=$(find_release_binary ssservice)
  current_method=$(jq -er '.method' "${CONFIG_PATH}")

  if ! "${new_ssserver}" --version >/dev/null 2>&1; then
    log_error "$(l10n "The downloaded ssserver binary failed its version check." "下载的 ssserver 未通过版本检查。")"
    return 1
  fi
  if ! "${new_ssservice}" genkey -m "${current_method}" >/dev/null 2>&1; then
    log_error "$(l10n "The downloaded release does not support the configured cipher method: ${current_method}" "下载的版本不支持当前加密方法：${current_method}")"
    return 1
  fi

  old_ssserver="${TMP_DIR}/ssserver.previous"
  old_ssservice="${TMP_DIR}/ssservice.previous"
  cp -a "${BIN_DIR}/ssserver" "${old_ssserver}"
  cp -a "${BIN_DIR}/ssservice" "${old_ssservice}"

  staged_ssserver=$(mktemp "${BIN_DIR}/.ssserver.update.XXXXXX")
  staged_ssservice=$(mktemp "${BIN_DIR}/.ssservice.update.XXXXXX")
  install -m 0755 "${new_ssserver}" "${staged_ssserver}"
  install -m 0755 "${new_ssservice}" "${staged_ssservice}"
  if ! was_active=$(service_was_active_before_change); then
    rm -f "${staged_ssserver}" "${staged_ssservice}"
    return 1
  fi

  if ! mv -f "${staged_ssserver}" "${BIN_DIR}/ssserver"; then
    rm -f "${staged_ssserver}" "${staged_ssservice}"
    return 1
  fi
  staged_ssserver=""
  if ! mv -f "${staged_ssservice}" "${BIN_DIR}/ssservice"; then
    atomic_install_file "${old_ssserver}" "${BIN_DIR}/ssserver" 0755
    rm -f "${staged_ssservice}"
    return 1
  fi
  staged_ssservice=""

  if [[ "${was_active}" == "y" ]] && ! restart_and_verify_service; then
    log_warn "$(l10n "The updated service failed to restart; restoring the previous binaries." "更新后服务重启失败，正在恢复旧版程序。")"
    atomic_install_file "${old_ssserver}" "${BIN_DIR}/ssserver" 0755
    atomic_install_file "${old_ssservice}" "${BIN_DIR}/ssservice" 0755
    restart_and_verify_service || true
    return 1
  fi

  rm -f "${staged_ssserver}" "${staged_ssservice}"
  log_info "$(l10n "Shadowsocks-rust was updated to ${INSTALL_VERSION}. The existing configuration was preserved." "Shadowsocks-rust 已更新至 ${INSTALL_VERSION}，现有配置保持不变。")"
  if [[ "${was_active}" != "y" ]]; then
    log_info "$(l10n "The service was stopped before the update and remains stopped." "服务在更新前处于停止状态，更新后仍保持停止。")"
  fi
}

atomic_install_file() {
  local source_path="$1"
  local destination_path="$2"
  local mode="$3"
  local destination_dir=""
  local destination_name=""
  local staged_path=""

  destination_dir=${destination_path%/*}
  destination_name=${destination_path##*/}
  staged_path=$(mktemp "${destination_dir}/.${destination_name}.replace.XXXXXX")
  if ! install -m "${mode}" "${source_path}" "${staged_path}"; then
    rm -f "${staged_path}"
    return 1
  fi
  mv -f "${staged_path}" "${destination_path}"
}

restart_and_verify_service() {
  systemctl restart "${SERVICE_NAME}" || return 1
  wait_for_service_active
}

query_service_active_state() {
  local state=""

  if state=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null); then
    :
  fi

  case "${state}" in
    active|inactive|failed|activating|deactivating|reloading|maintenance)
      printf '%s' "${state}"
      ;;
    *)
      log_error "$(l10n "Could not determine the active state of ${SERVICE_NAME}." "无法确定 ${SERVICE_NAME} 的运行状态。")"
      return 1
      ;;
  esac
}

query_service_enabled_state() {
  local state=""

  if state=$(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null); then
    :
  fi

  case "${state}" in
    enabled|enabled-runtime|linked|linked-runtime|alias|static|indirect|generated|transient|disabled|masked|masked-runtime|not-found)
      printf '%s' "${state}"
      ;;
    *)
      log_error "$(l10n "Could not determine the boot state of ${SERVICE_NAME}." "无法确定 ${SERVICE_NAME} 的开机启动状态。")"
      return 1
      ;;
  esac
}

service_was_active_before_change() {
  local state=""

  state=$(query_service_active_state) || return 1
  case "${state}" in
    active) printf '%s' "y" ;;
    inactive|failed) printf '%s' "n" ;;
    *)
      log_error "$(l10n "${SERVICE_NAME} is in state '${state}'. Wait for it to settle before changing files." "${SERVICE_NAME} 当前状态为 ${state}，请等待状态稳定后再修改文件。")"
      return 1
      ;;
  esac
}

wait_for_service_active() {
  local attempt=0
  local state=""

  while (( attempt < 5 )); do
    state=$(query_service_active_state) || return 1
    if [[ "${state}" == "active" ]]; then
      return 0
    fi
    if [[ "${state}" == "failed" ]]; then
      return 1
    fi
    attempt=$((attempt + 1))
    if (( attempt < 5 )); then
      sleep 1
    fi
  done
  return 1
}

wait_for_service_stopped() {
  local attempt=0
  local state=""

  while (( attempt < 5 )); do
    state=$(query_service_active_state) || return 1
    case "${state}" in
      inactive|failed) return 0 ;;
    esac
    attempt=$((attempt + 1))
    if (( attempt < 5 )); then
      sleep 1
    fi
  done
  return 1
}

find_release_binary() {
  local binary="$1"
  local binary_path=""

  binary_path=$(find "${TMP_DIR}" -type f -name "${binary}" -perm -u+x | head -n1)
  if [[ -z "${binary_path}" ]]; then
    log_error "$(l10n "Could not find ${binary} in the release archive." "在发布压缩包中找不到 ${binary}。")"
    return 1
  fi

  printf '%s' "${binary_path}"
}

uninstall_action() {
  local active_state=""
  local enabled_state=""
  local account_cleanup_pending="n"
  local firewall_cleanup_pending="n"
  local remove_config="n"

  if ! has_installation_artifacts; then
    log_info "$(l10n "No Shadowsocks-rust installation was found." "未发现 Shadowsocks-rust 安装。")"
    return 0
  fi

  if [[ "$(prompt_yes_no "$(l10n "Uninstall Shadowsocks-rust?" "确定卸载 Shadowsocks-rust？")" "n")" != "y" ]]; then
    log_info "$(l10n "Uninstall cancelled." "已取消卸载。")"
    return 0
  fi

  if [[ -d "${CONFIG_DIR}" ]]; then
    if [[ "$(prompt_yes_no "$(l10n "Also remove the configuration and its backups?" "是否同时删除配置和备份？")" "n")" == "y" ]]; then
      remove_config="y"
    fi
  fi

  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  active_state=$(query_service_active_state) || return 1
  enabled_state=$(query_service_enabled_state) || return 1
  case "${active_state}" in
    inactive|failed) ;;
    *)
      log_error "$(l10n "${SERVICE_NAME} is still in state '${active_state}'; no files were removed." "${SERVICE_NAME} 当前仍为 ${active_state} 状态，未删除任何文件。")"
      return 1
      ;;
  esac
  case "${enabled_state}" in
    disabled|masked|masked-runtime|static|indirect|generated|transient|not-found) ;;
    *)
      log_error "$(l10n "${SERVICE_NAME} is still enabled (${enabled_state}); no files were removed." "${SERVICE_NAME} 仍处于开机启用状态（${enabled_state}），未删除任何文件。")"
      return 1
      ;;
  esac

  if ! remove_recorded_firewall_rule; then
    log_warn "$(l10n "Some installer-managed firewall rules could not be removed. Their ownership records remain at ${FIREWALL_STATE_PATH}." "部分由脚本管理的防火墙规则无法删除，所有权记录仍保留在 ${FIREWALL_STATE_PATH}。")"
    if [[ "$(prompt_yes_no "$(l10n "Continue uninstalling the program and retain the firewall cleanup records?" "是否继续卸载程序并保留防火墙清理记录？")" "n")" != "y" ]]; then
      log_error "$(l10n "Uninstall stopped before removing program files." "卸载已在删除程序文件前停止。")"
      return 1
    fi
    firewall_cleanup_pending="y"
  fi

  rm -f "${SERVICE_PATH}" "${BIN_DIR}/ssserver" "${BIN_DIR}/ssservice"
  systemctl daemon-reload
  systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true

  if [[ "${remove_config}" == "y" ]]; then
    rm -rf "${CONFIG_DIR}"
    if ! remove_owned_service_account; then
      account_cleanup_pending="y"
    fi
    if [[ "${firewall_cleanup_pending}" == "y" || "${account_cleanup_pending}" == "y" ]]; then
      rm -f "${CONFIG_NAME_PATH}"
      log_warn "$(l10n "Shadowsocks-rust program files and configuration were removed, but some owned resources still need cleanup. Retry Uninstall later; state was retained at ${STATE_DIR}." "Shadowsocks-rust 程序和配置已删除，但仍有脚本拥有的资源需要清理。请稍后重新执行卸载；状态保留在 ${STATE_DIR}。")"
    else
      rm -rf "${STATE_DIR}"
      log_info "$(l10n "Shadowsocks-rust and its configuration were removed." "Shadowsocks-rust 及其配置已删除。")"
    fi
  elif [[ ! -d "${CONFIG_DIR}" ]]; then
    if ! remove_owned_service_account; then
      account_cleanup_pending="y"
    fi
    if [[ "${firewall_cleanup_pending}" != "y" && "${account_cleanup_pending}" != "y" ]]; then
      rm -rf "${STATE_DIR}"
    fi
    if [[ "${account_cleanup_pending}" == "y" ]]; then
      log_warn "$(l10n "Shadowsocks-rust program files were removed, but its owned service account still needs cleanup. Retry Uninstall later; state was retained at ${STATE_DIR}." "Shadowsocks-rust 程序已删除，但脚本创建的服务账号仍需清理。请稍后重新执行卸载；状态保留在 ${STATE_DIR}。")"
    else
      log_info "$(l10n "Shadowsocks-rust was removed." "Shadowsocks-rust 已卸载。")"
    fi
  else
    log_info "$(l10n "Shadowsocks-rust was removed. Configuration retained at ${CONFIG_DIR}." "Shadowsocks-rust 已卸载，配置保留在 ${CONFIG_DIR}。")"
  fi

  [[ "${account_cleanup_pending}" == "n" ]]
}

has_installation_artifacts() {
  [[ -e "${BIN_DIR}/ssserver" || -e "${BIN_DIR}/ssservice" || -e "${SERVICE_PATH}" || -L "${SERVICE_PATH}" || -d "${CONFIG_DIR}" || -f "${FIREWALL_STATE_PATH}" || -f "${USER_MARKER_PATH}" || -f "${GROUP_MARKER_PATH}" ]]
}

has_program_artifacts() {
  [[ -e "${BIN_DIR}/ssserver" || -e "${BIN_DIR}/ssservice" || -e "${SERVICE_PATH}" || -L "${SERVICE_PATH}" ]]
}

remove_owned_service_account() {
  local failed="n"

  if [[ -f "${USER_MARKER_PATH}" ]]; then
    if ! id -u "${SERVICE_USER}" >/dev/null 2>&1 || userdel "${SERVICE_USER}" >/dev/null 2>&1; then
      rm -f "${USER_MARKER_PATH}"
    else
      log_warn "$(l10n "Could not remove service user ${SERVICE_USER}." "无法删除服务用户 ${SERVICE_USER}。")"
      failed="y"
    fi
  fi

  if [[ -f "${GROUP_MARKER_PATH}" ]]; then
    if ! getent group "${SERVICE_USER}" >/dev/null 2>&1 || groupdel "${SERVICE_USER}" >/dev/null 2>&1; then
      rm -f "${GROUP_MARKER_PATH}"
    else
      log_warn "$(l10n "Could not remove service group ${SERVICE_USER}." "无法删除服务组 ${SERVICE_USER}。")"
      failed="y"
    fi
  fi

  [[ "${failed}" == "n" ]]
}

service_menu() {
  local choice=""

  while true; do
    printf '\n%s\n' "$(l10n "Service control" "服务控制")"
    printf '  1) %s\n' "$(l10n "Start service" "启动服务")"
    printf '  2) %s\n' "$(l10n "Stop service" "停止服务")"
    printf '  3) %s\n' "$(l10n "Restart service" "重启服务")"
    printf '  0) %s\n\n' "$(l10n "Back" "返回")"

    if ! read -r -p "$(l10n "Select an option" "请选择功能") [0-3]: " choice; then
      printf '\n'
      return 0
    fi

    case "${choice}" in
      1) run_action start start_service_action; return 0 ;;
      2) run_action stop stop_service_action; return 0 ;;
      3) run_action restart restart_service_action; return 0 ;;
      0) return 0 ;;
      *) log_warn "$(l10n "Invalid selection. Please choose a listed number." "选择无效，请输入菜单中的数字。")" ;;
    esac
  done
}

start_service_action() {
  require_installed
  systemctl start "${SERVICE_NAME}"
  if ! wait_for_service_active; then
    log_error "$(l10n "${SERVICE_NAME} did not reach the active state." "${SERVICE_NAME} 未进入运行状态。")"
    return 1
  fi
  log_info "$(l10n "The Shadowsocks-rust service is running." "Shadowsocks-rust 服务已启动。")"
}

stop_service_action() {
  require_installed
  systemctl stop "${SERVICE_NAME}"
  if ! wait_for_service_stopped; then
    log_error "$(l10n "${SERVICE_NAME} did not stop cleanly." "${SERVICE_NAME} 未能正常停止。")"
    return 1
  fi
  log_info "$(l10n "The Shadowsocks-rust service is stopped." "Shadowsocks-rust 服务已停止。")"
}

restart_service_action() {
  require_installed
  if ! restart_and_verify_service; then
    log_error "$(l10n "${SERVICE_NAME} did not restart cleanly." "${SERVICE_NAME} 未能正常重启。")"
    return 1
  fi
  log_info "$(l10n "The Shadowsocks-rust service was restarted." "Shadowsocks-rust 服务已重启。")"
}

view_status_action() {
  local active_state="unknown"
  local enabled_state="unknown"
  local version="unknown"

  require_installed
  active_state=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)
  enabled_state=$(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true)
  version=$("${BIN_DIR}/ssserver" --version 2>/dev/null | head -n1 || true)

  printf '\n%s\n' "$(l10n "Shadowsocks-rust service status" "Shadowsocks-rust 运行状态")"
  printf '%-18s %s\n' "$(l10n "Version:" "版本：")" "$(status_value_label "${version:-unknown}")"
  printf '%-18s %s\n' "$(l10n "Active state:" "运行状态：")" "$(status_value_label "${active_state:-unknown}")"
  printf '%-18s %s\n\n' "$(l10n "Boot state:" "开机启动：")" "$(status_value_label "${enabled_state:-unknown}")"
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

status_value_label() {
  local value="$1"

  if [[ "${SCRIPT_LANG:-en}" != "zh" ]]; then
    printf '%s' "${value}"
    return 0
  fi

  case "${value}" in
    active) printf '%s' "运行中" ;;
    inactive) printf '%s' "未运行" ;;
    activating) printf '%s' "正在启动" ;;
    deactivating) printf '%s' "正在停止" ;;
    failed) printf '%s' "失败" ;;
    enabled) printf '%s' "已启用" ;;
    disabled) printf '%s' "未启用" ;;
    static) printf '%s' "静态" ;;
    masked) printf '%s' "已屏蔽" ;;
    not-found|unknown|"") printf '%s' "未知" ;;
    *) printf '%s' "${value}" ;;
  esac
}

require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  log_info "$(l10n "jq is missing; installing the required package." "缺少 jq，正在安装所需软件包。")"
  install_prerequisites
  if ! command -v jq >/dev/null 2>&1; then
    log_error "$(l10n "jq is required for configuration management and could not be installed." "配置管理需要 jq，但未能完成安装。")"
    return 1
  fi
}

validate_server_config() {
  local config_path="$1"
  local method=""
  local password=""

  if [[ -L "${config_path}" ]]; then
    log_error "$(l10n "Refusing to manage a symbolic-link configuration: ${config_path}" "拒绝管理符号链接配置：${config_path}")"
    return 1
  fi

  if [[ ! -f "${config_path}" ]]; then
    log_error "$(l10n "Configuration file not found: ${config_path}" "找不到配置文件：${config_path}")"
    return 1
  fi

  if ! jq -e '
    type == "object" and
    (.server | type == "string" and length > 0 and (test("[\u0000-\u001F\u007F]") | not)) and
    (.server_port | type == "number" and . == floor and . >= 1 and . <= 65535) and
    (.password | type == "string" and length > 0 and (test("[\u0000-\u001F\u007F]") | not)) and
    (.method | type == "string" and length > 0 and (test("[\u0000-\u001F\u007F]") | not)) and
    (.mode | type == "string" and (. == "tcp_only" or . == "udp_only" or . == "tcp_and_udp")) and
    (.timeout | type == "number" and . == floor and . >= 1)
  ' "${config_path}" >/dev/null 2>&1; then
    log_error "$(l10n "The Shadowsocks-rust configuration is invalid or has unsupported field types." "Shadowsocks-rust 配置无效，或字段类型不受支持。")"
    return 1
  fi

  method=$(jq -er '.method' "${config_path}")
  password=$(jq -er '.password' "${config_path}")
  if ! validate_password_for_method "${method}" "${password}"; then
    log_error "$(l10n "The configured password/key is invalid for method ${method}." "当前密码/key 不适用于加密方法 ${method}。")"
    return 1
  fi
}

load_server_config() {
  local config_path="${1:-${CONFIG_PATH}}"

  validate_server_config "${config_path}"
  LISTEN_ADDRESS=$(jq -er '.server' "${config_path}")
  SERVER_PORT=$(jq -er '.server_port | tostring' "${config_path}")
  PASSWORD=$(jq -er '.password' "${config_path}")
  METHOD=$(jq -er '.method' "${config_path}")
  MODE=$(jq -er '.mode' "${config_path}")
  TIMEOUT_SECONDS=$(jq -er '.timeout | tostring' "${config_path}")

  if [[ -r "${CONFIG_NAME_PATH}" ]]; then
    CONFIG_NAME=$(head -n1 "${CONFIG_NAME_PATH}")
  else
    CONFIG_NAME="shadowsocks-rust"
  fi
}

modify_config_action() {
  local old_port=""
  local old_method=""
  local old_password=""
  local backup_path=""
  local request_path=""
  local staged_path=""
  local change_password="n"
  local was_active="n"
  local firewall_change_attempted="n"
  local firewall_manager_for_change=""
  local firewall_zone_for_change=""

  require_installed
  require_jq
  load_server_config "${CONFIG_PATH}"
  old_port="${SERVER_PORT}"
  old_method="${METHOD}"
  old_password="${PASSWORD}"

  printf '\n%s\n' "$(l10n "Modify Shadowsocks-rust configuration" "修改 Shadowsocks-rust 配置")"
  LISTEN_ADDRESS=$(prompt_listen_address "${LISTEN_ADDRESS}")
  SERVER_PORT=$(prompt_default "$(l10n "Server port" "服务端口")" "${SERVER_PORT}")
  METHOD=$(prompt_default "$(l10n "Cipher method" "加密方法")" "${METHOD}")
  MODE=$(prompt_default "$(l10n "Traffic mode" "流量模式")" "${MODE}")
  TIMEOUT_SECONDS=$(prompt_default "$(l10n "Timeout in seconds" "超时时间（秒）")" "${TIMEOUT_SECONDS}")
  CONFIG_NAME=$(prompt_default "$(l10n "Node name for the share link" "分享链接中的节点名称")" "${CONFIG_NAME}")

  validate_non_control_value "$(l10n "Bind address" "监听地址")" "${LISTEN_ADDRESS}"
  validate_non_control_value "$(l10n "Cipher method" "加密方法")" "${METHOD}"
  validate_non_control_value "$(l10n "Node name" "节点名称")" "${CONFIG_NAME}"
  validate_port "${SERVER_PORT}"
  validate_timeout "${TIMEOUT_SECONDS}"
  validate_mode "${MODE}"

  if ! "${BIN_DIR}/ssservice" genkey -m "${METHOD}" >/dev/null 2>&1; then
    log_error "$(l10n "The installed ssservice does not support method: ${METHOD}" "当前 ssservice 不支持加密方法：${METHOD}")"
    return 1
  fi

  if [[ "${METHOD}" != "${old_method}" ]] && ! validate_password_for_method "${METHOD}" "${old_password}"; then
    change_password="y"
    log_warn "$(l10n "The existing password/key is incompatible with the new method and must be replaced." "现有密码/key 与新加密方法不兼容，必须重新设置。")"
  else
    change_password=$(prompt_yes_no "$(l10n "Change the password/key?" "是否修改密码/key？")" "n")
  fi

  if [[ "${change_password}" == "y" ]]; then
    PASSWORD=$(prompt_password "${METHOD}")
    if [[ -z "${PASSWORD}" ]]; then
      PASSWORD=$("${BIN_DIR}/ssservice" genkey -m "${METHOD}" | tail -n1 | tr -d '\r')
    fi
  else
    PASSWORD="${old_password}"
  fi

  request_path=$(mktemp "${CONFIG_DIR}/.config.request.XXXXXX")
  staged_path=$(mktemp "${CONFIG_DIR}/.config.staged.XXXXXX")
  chmod 0600 "${request_path}" "${staged_path}"
  write_config_request "${request_path}"

  if ! jq --slurpfile changes "${request_path}" '. * $changes[0]' "${CONFIG_PATH}" >"${staged_path}"; then
    rm -f "${request_path}" "${staged_path}"
    log_error "$(l10n "Could not render the updated configuration." "无法生成更新后的配置。")"
    return 1
  fi
  rm -f "${request_path}"
  validate_server_config "${staged_path}"

  chmod 0640 "${staged_path}"
  chown root:"${SERVICE_USER}" "${staged_path}"
  if ! was_active=$(service_was_active_before_change); then
    rm -f "${staged_path}"
    return 1
  fi

  if [[ "${SERVER_PORT}" != "${old_port}" ]]; then
    detect_firewall_manager
    if [[ -n "${FIREWALL_MANAGER}" ]] && [[ "$(prompt_yes_no "$(l10n "Open the new TCP/UDP port ${SERVER_PORT} in ${FIREWALL_MANAGER}?" "是否在 ${FIREWALL_MANAGER} 中放行新的 TCP/UDP 端口 ${SERVER_PORT}？")" "y")" == "y" ]]; then
      firewall_manager_for_change="${FIREWALL_MANAGER}"
      firewall_change_attempted="y"
      OPEN_FIREWALL="y"
      if ! maybe_open_firewall; then
        firewall_zone_for_change="${FIREWALLD_ZONE}"
        cleanup_firewall_rules_for_failed_change \
          "${firewall_manager_for_change}" "${SERVER_PORT}" \
          "${FIREWALL_TCP_CHANGED}" "${FIREWALL_UDP_CHANGED}" \
          "${firewall_zone_for_change}"
        rm -f "${staged_path}"
        log_error "$(l10n "The new firewall rules could not be prepared; configuration and service were not changed." "无法准备新端口的防火墙规则；配置与服务均未更改。")"
        return 1
      fi
      firewall_zone_for_change="${FIREWALLD_ZONE}"
    fi
  fi

  backup_path=$(next_backup_path "${CONFIG_PATH}")
  if ! cp -a "${CONFIG_PATH}" "${backup_path}"; then
    if [[ "${firewall_change_attempted}" == "y" ]]; then
      cleanup_firewall_rules_for_failed_change \
        "${firewall_manager_for_change}" "${SERVER_PORT}" \
        "${FIREWALL_TCP_CHANGED}" "${FIREWALL_UDP_CHANGED}" \
        "${firewall_zone_for_change}"
    fi
    rm -f "${staged_path}"
    return 1
  fi
  if ! mv -f "${staged_path}" "${CONFIG_PATH}"; then
    if [[ "${firewall_change_attempted}" == "y" ]]; then
      cleanup_firewall_rules_for_failed_change \
        "${firewall_manager_for_change}" "${SERVER_PORT}" \
        "${FIREWALL_TCP_CHANGED}" "${FIREWALL_UDP_CHANGED}" \
        "${firewall_zone_for_change}"
    fi
    rm -f "${staged_path}"
    return 1
  fi

  if [[ "${was_active}" == "y" ]] && ! restart_and_verify_service; then
    log_warn "$(l10n "The service failed to restart; restoring the previous configuration." "服务重启失败，正在恢复原配置。")"
    atomic_install_file "${backup_path}" "${CONFIG_PATH}" 0640
    chown root:"${SERVICE_USER}" "${CONFIG_PATH}"
    restart_and_verify_service || true
    if [[ "${firewall_change_attempted}" == "y" ]]; then
      cleanup_firewall_rules_for_failed_change \
        "${firewall_manager_for_change}" "${SERVER_PORT}" \
        "${FIREWALL_TCP_CHANGED}" "${FIREWALL_UDP_CHANGED}" \
        "${firewall_zone_for_change}"
    fi
    return 1
  fi

  ensure_state_dir
  printf '%s\n' "${CONFIG_NAME}" >"${CONFIG_NAME_PATH}"
  chmod 0600 "${CONFIG_NAME_PATH}"

  if [[ "${SERVER_PORT}" != "${old_port}" ]]; then
    if has_owned_firewall_rules_for_port "${old_port}"; then
      if [[ "$(prompt_yes_no "$(l10n "Remove installer-managed firewall rules for the old port ${old_port}?" "是否删除脚本为旧端口 ${old_port} 添加的防火墙规则？")" "y")" == "y" ]]; then
        if ! remove_recorded_firewall_rule "${old_port}"; then
          log_warn "$(l10n "Some firewall rules for old port ${old_port} remain recorded for a later cleanup retry." "旧端口 ${old_port} 的部分防火墙规则未能删除，记录已保留，稍后可重试清理。")"
        fi
      fi
    fi
  fi

  log_info "$(l10n "Configuration updated. Backup: ${backup_path}" "配置已更新，备份位置：${backup_path}")"
  if [[ "${was_active}" != "y" ]]; then
    log_info "$(l10n "The service was stopped and remains stopped. Start it when you are ready." "服务原本处于停止状态，现仍保持停止；准备好后请手动启动。")"
  fi
  view_config_action
}

write_config_request() {
  local output_path="$1"

  cat >"${output_path}" <<EOF
{
  "server": "$(json_escape "${LISTEN_ADDRESS}")",
  "server_port": ${SERVER_PORT},
  "password": "$(json_escape "${PASSWORD}")",
  "method": "$(json_escape "${METHOD}")",
  "mode": "$(json_escape "${MODE}")",
  "timeout": ${TIMEOUT_SECONDS}
}
EOF
}

next_backup_path() {
  local source_path="$1"
  local suffix=""
  local candidate=""
  local counter=0

  suffix=$(date +%Y%m%d-%H%M%S)
  candidate="${source_path}.${suffix}.bak"
  while [[ -e "${candidate}" ]]; do
    counter=$((counter + 1))
    candidate="${source_path}.${suffix}.${counter}.bak"
  done
  printf '%s' "${candidate}"
}

validate_non_control_value() {
  local label="$1"
  local value="$2"

  if [[ -z "${value}" || "${value}" =~ [[:cntrl:]] ]]; then
    log_error "$(l10n "${label} cannot be empty or contain control characters." "${label}不能为空或包含控制字符。")"
    return 1
  fi
}

view_config_action() {
  local public_ip=""
  local ss_uri=""
  local reveal_secret="n"

  require_installed
  require_jq
  load_server_config "${CONFIG_PATH}"

  printf '\n%s\n' "$(l10n "Shadowsocks-rust configuration" "Shadowsocks-rust 配置信息")"
  jq 'if has("password") then .password = "********" else . end' "${CONFIG_PATH}"

  reveal_secret=$(prompt_yes_no "$(l10n "Show the password/key and share link?" "是否显示密码/key 和分享链接？")" "n")
  if [[ "${reveal_secret}" != "y" ]]; then
    return 0
  fi

  printf '\n%s %s\n' "$(l10n "Password/key:" "密码/key：")" "${PASSWORD}"

  public_ip=$(detect_public_ip)
  if [[ -n "${public_ip}" ]]; then
    ss_uri=$(build_ss_uri "${public_ip}")
    printf '\n%s\n  %s\n' "$(l10n "Share link:" "分享链接：")" "${ss_uri}"
  else
    log_warn "$(l10n "Public IP detection failed; the share link could not be generated." "公网 IP 检测失败，无法生成分享链接。")"
  fi
}

l10n() {
  local english="$1"
  local chinese="$2"

  if [[ "${SCRIPT_LANG:-en}" == "zh" ]]; then
    printf '%s' "${chinese}"
  else
    printf '%s' "${english}"
  fi
}

detect_system_timezone() {
  local timezone=""
  local localtime_target=""

  if command -v timedatectl >/dev/null 2>&1; then
    timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  fi

  if [[ -z "${timezone}" && -r /etc/timezone ]]; then
    timezone=$(head -n1 /etc/timezone 2>/dev/null || true)
  fi

  if [[ -z "${timezone}" && -L /etc/localtime ]] && command -v readlink >/dev/null 2>&1; then
    localtime_target=$(readlink /etc/localtime 2>/dev/null || true)
    if [[ "${localtime_target}" == *zoneinfo/* ]]; then
      timezone=${localtime_target#*zoneinfo/}
    fi
  fi

  printf '%s' "${timezone}"
}

default_language_for_timezone() {
  local timezone="${1:-}"
  local normalized=""

  normalized=$(printf '%s' "${timezone}" | tr '[:upper:]' '[:lower:]')
  case "${normalized}" in
    asia/shanghai|*/asia/shanghai|shanghai|prc)
      printf '%s' "zh"
      ;;
    *)
      printf '%s' "en"
      ;;
  esac
}

normalize_language() {
  case "${1,,}" in
    1|en|eng|english)
      printf '%s' "en"
      ;;
    2|zh|cn|zh-cn|zh_cn|chinese|中文)
      printf '%s' "zh"
      ;;
    *)
      return 1
      ;;
  esac
}

choose_language() {
  local default_language="${1:-en}"
  local default_choice="1"
  local choice=""
  local normalized=""

  if [[ "${default_language}" == "zh" ]]; then
    default_choice="2"
  fi

  while true; do
    printf '\nSelect script language / 选择脚本语言\n' >&2
    printf '  1) English\n' >&2
    printf '  2) 简体中文\n' >&2
    if ! read -r -p "Choice / 请选择 [${default_choice}]: " choice; then
      choice="${default_choice}"
    fi
    choice=${choice:-${default_choice}}

    if normalized=$(normalize_language "${choice}"); then
      SCRIPT_LANG="${normalized}"
      return 0
    fi

    printf '[WARN] Invalid selection / 选择无效，请重新输入。\n' >&2
  done
}

initialize_language() {
  local requested_language="${SCRIPT_LANG:-}"
  local timezone=""
  local default_language="en"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --lang)
        if [[ "$#" -lt 2 ]]; then
          printf '[ERROR] --lang requires en or zh. / --lang 需要 en 或 zh。\n' >&2
          exit 2
        fi
        requested_language="$2"
        shift 2
        ;;
      --lang=*)
        requested_language=${1#--lang=}
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        printf '[ERROR] Unknown option: %s / 未知选项：%s\n' "$1" "$1" >&2
        print_usage >&2
        exit 2
        ;;
    esac
  done

  if [[ -n "${requested_language}" ]]; then
    if SCRIPT_LANG=$(normalize_language "${requested_language}"); then
      return 0
    fi
    printf '[ERROR] Unsupported language: %s / 不支持的语言：%s\n' "${requested_language}" "${requested_language}" >&2
    exit 2
  fi

  timezone=$(detect_system_timezone)
  default_language=$(default_language_for_timezone "${timezone}")
  if [[ -t 0 ]]; then
    choose_language "${default_language}"
  else
    SCRIPT_LANG="${default_language}"
  fi
}

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--lang en|zh]
用法：${SCRIPT_NAME} [--lang en|zh]
EOF
}

is_installed() {
  [[ -x "${BIN_DIR}/ssserver" && -x "${BIN_DIR}/ssservice" && -f "${CONFIG_PATH}" && -f "${SERVICE_PATH}" ]]
}

installation_status_label() {
  if is_installed; then
    l10n "installed" "已安装"
  else
    l10n "not installed" "未安装"
  fi
}

main_menu() {
  local choice=""

  while true; do
    print_banner
    printf '%s: %s\n\n' "$(l10n "Status" "状态")" "$(installation_status_label)"
    printf '  1) %s\n' "$(l10n "Install Shadowsocks-rust" "安装 Shadowsocks-rust")"
    printf '  2) %s\n' "$(l10n "Update Shadowsocks-rust" "更新 Shadowsocks-rust")"
    printf '  3) %s\n' "$(l10n "Uninstall Shadowsocks-rust" "卸载 Shadowsocks-rust")"
    printf '  4) %s\n' "$(l10n "Start / stop / restart service" "启动 / 停止 / 重启服务")"
    printf '  5) %s\n' "$(l10n "Modify configuration" "修改配置信息")"
    printf '  6) %s\n' "$(l10n "View configuration" "查看配置信息")"
    printf '  7) %s\n' "$(l10n "View service status" "查看运行状态")"
    printf '  8) %s\n' "$(l10n "Switch language" "切换脚本语言")"
    printf '  0) %s\n\n' "$(l10n "Exit" "退出")"

    if ! read -r -p "$(l10n "Select an option" "请选择功能") [0-8]: " choice; then
      printf '\n'
      return 0
    fi

    case "${choice}" in
      1) run_action install install_action ;;
      2) run_action update update_action ;;
      3) run_action uninstall uninstall_action ;;
      4) service_menu ;;
      5) run_action modify modify_config_action ;;
      6) run_action view view_config_action ;;
      7) run_action status view_status_action ;;
      8) choose_language "${SCRIPT_LANG}" ;;
      0|q|Q) return 0 ;;
      *) log_warn "$(l10n "Invalid selection. Please choose a listed number." "选择无效，请输入菜单中的数字。")" ;;
    esac
  done
}

run_action() {
  local action_function="$2"
  local status=0

  trap - ERR
  set +e
  (
    set -Eeuo pipefail
    TMP_DIR=""
    trap cleanup EXIT
    trap on_error ERR
    "${action_function}"
  )
  status=$?
  set -e
  restore_error_trap

  if (( status != 0 )); then
    log_error "$(l10n "The selected operation did not complete." "所选操作未完成。")"
  fi

  return 0
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "$(l10n "Run this script as root, for example: sudo bash ${SCRIPT_NAME}" "请使用 root 权限运行此脚本，例如：sudo bash ${SCRIPT_NAME}")"
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_error "$(l10n "systemctl is required. This script only supports systemd-based Linux systems." "此脚本需要 systemctl，仅支持使用 systemd 的 Linux 系统。")"
    exit 1
  fi

  if [[ ! -d /run/systemd/system ]]; then
    log_error "$(l10n "systemd does not appear to be the active init system on this host." "当前主机似乎未使用 systemd 作为 init 系统。")"
    exit 1
  fi
}

install_prerequisites() {
  local missing=()
  local packages=()
  local unmapped=()
  local required=(
    base64
    cat
    chmod
    chown
    cp
    curl
    date
    find
    getent
    grep
    groupadd
    groupdel
    head
    id
    install
    jq
    mkdir
    mktemp
    mv
    od
    readlink
    rm
    sed
    sha256sum
    sleep
    tail
    tar
    tr
    uname
    useradd
    userdel
    xz
  )
  local cmd
  local manager
  local package

  for cmd in "${required[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return
  fi

  manager=$(detect_package_manager)
  if [[ -z "${manager}" ]]; then
    log_error "$(l10n "Could not install missing prerequisites automatically. Missing commands: $(join_words "${missing[@]}")" "无法自动安装缺失的依赖命令：$(join_words "${missing[@]}")")"
    exit 1
  fi

  for cmd in "${missing[@]}"; do
    package=$(package_for_command "${manager}" "${cmd}")
    if [[ -z "${package}" ]]; then
      unmapped+=("${cmd}")
    else
      add_unique_package "${package}"
    fi
  done

  if [[ "${#unmapped[@]}" -gt 0 ]]; then
    log_error "$(l10n "No package mapping for missing commands on ${manager}: $(join_words "${unmapped[@]}")" "在 ${manager} 上找不到这些命令对应的软件包：$(join_words "${unmapped[@]}")")"
    exit 1
  fi

  log_info "$(l10n "Missing commands: $(join_words "${missing[@]}")" "缺失命令：$(join_words "${missing[@]}")")"
  log_info "$(l10n "Installing minimal prerequisite packages with ${manager}: $(join_words "${packages[@]}")" "正在使用 ${manager} 安装最小依赖包：$(join_words "${packages[@]}")")"

  case "${manager}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    zypper)
      zypper --non-interactive install "${packages[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${packages[@]}"
      ;;
    *)
      log_error "$(l10n "Unsupported package manager: ${manager}" "不支持的软件包管理器：${manager}")"
      exit 1
      ;;
  esac

  missing=()
  for cmd in "${required[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log_error "$(l10n "Prerequisites are still missing after package installation: $(join_words "${missing[@]}")" "安装软件包后仍缺少依赖命令：$(join_words "${missing[@]}")")"
    exit 1
  fi
}

join_words() {
  local IFS=' '
  printf '%s' "$*"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s' "apt"
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s' "dnf"
  elif command -v yum >/dev/null 2>&1; then
    printf '%s' "yum"
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s' "zypper"
  elif command -v pacman >/dev/null 2>&1; then
    printf '%s' "pacman"
  fi
}

package_for_command() {
  local manager="$1"
  local cmd="$2"

  case "${cmd}" in
    base64|cat|chmod|chown|cp|date|head|id|install|mkdir|mktemp|mv|od|readlink|rm|sha256sum|sleep|tail|tr|uname)
      printf '%s' "coreutils"
      ;;
    curl)
      printf '%s' "curl"
      ;;
    find)
      printf '%s' "findutils"
      ;;
    getent)
      case "${manager}" in
        apt) printf '%s' "libc-bin" ;;
        dnf|yum) printf '%s' "glibc-common" ;;
        zypper|pacman) printf '%s' "glibc" ;;
      esac
      ;;
    grep)
      printf '%s' "grep"
      ;;
    jq)
      printf '%s' "jq"
      ;;
    groupadd|groupdel|useradd|userdel)
      case "${manager}" in
        apt) printf '%s' "passwd" ;;
        dnf|yum) printf '%s' "shadow-utils" ;;
        zypper|pacman) printf '%s' "shadow" ;;
      esac
      ;;
    sed)
      printf '%s' "sed"
      ;;
    tar)
      printf '%s' "tar"
      ;;
    xz)
      case "${manager}" in
        apt) printf '%s' "xz-utils" ;;
        dnf|yum|zypper|pacman) printf '%s' "xz" ;;
      esac
      ;;
  esac
}

add_unique_package() {
  local package="$1"
  local existing

  for existing in "${packages[@]}"; do
    if [[ "${existing}" == "${package}" ]]; then
      return
    fi
  done

  packages+=("${package}")
}

collect_inputs() {
  print_banner

  VERSION_INPUT=$(prompt_default "$(l10n "Version to install (blank = latest stable release)" "要安装的版本（留空 = 最新稳定版）")" "")
  LISTEN_ADDRESS=$(prompt_listen_address "${DEFAULT_BIND_ADDRESS}")
  SERVER_PORT=$(prompt_default "$(l10n "Server port" "服务端口")" "${DEFAULT_PORT}")
  METHOD=$(select_method)
  PASSWORD=$(prompt_password "${METHOD}")
  MODE=$(prompt_default "$(l10n "Traffic mode" "流量模式")" "${DEFAULT_MODE}")
  TIMEOUT_SECONDS=$(prompt_default "$(l10n "Timeout in seconds" "超时时间（秒）")" "${DEFAULT_TIMEOUT}")
  CONFIG_NAME=$(prompt_default "$(l10n "Node name for the summary link" "分享链接中的节点名称")" "shadowsocks-rust")

  if [[ -n "${FIREWALL_MANAGER}" ]]; then
    OPEN_FIREWALL=$(prompt_yes_no "$(l10n "Detected ${FIREWALL_MANAGER}. Open TCP/UDP ${SERVER_PORT} automatically?" "检测到 ${FIREWALL_MANAGER}，是否自动放行 TCP/UDP ${SERVER_PORT}？")" "y")
  else
    OPEN_FIREWALL="n"
  fi

  validate_port "${SERVER_PORT}"
  validate_timeout "${TIMEOUT_SECONDS}"
  validate_mode "${MODE}"
  validate_non_control_value "$(l10n "Bind address" "监听地址")" "${LISTEN_ADDRESS}"
  validate_non_control_value "$(l10n "Node name" "节点名称")" "${CONFIG_NAME}"
}

fetch_release_metadata() {
  local endpoint

  if [[ -z "${VERSION_INPUT}" || "${VERSION_INPUT}" == "latest" ]]; then
    endpoint="${REPO_API_BASE}/latest"
  else
    VERSION_INPUT=$(normalize_version "${VERSION_INPUT}")
    endpoint="${REPO_API_BASE}/tags/${VERSION_INPUT}"
  fi

  log_info "$(l10n "Fetching release metadata from GitHub." "正在从 GitHub 获取发布信息。")"
  RELEASE_JSON=$(curl -fsSL "${endpoint}")
  INSTALL_VERSION=$(printf '%s\n' "${RELEASE_JSON}" | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -n1)

  if [[ -z "${INSTALL_VERSION}" ]]; then
    log_error "$(l10n "Could not determine the release version from GitHub." "无法从 GitHub 确定发布版本。")"
    exit 1
  fi
}

choose_release_asset() {
  local -a candidates=()
  local candidate

  mapfile -t candidates < <(asset_candidates "${INSTALL_VERSION}")

  for candidate in "${candidates[@]}"; do
    ASSET_URL=""
    if ASSET_URL=$(asset_url_from_release "${candidate}") && [[ -n "${ASSET_URL}" ]]; then
      ASSET_NAME="${candidate}"
      SHA256_URL="${ASSET_URL}.sha256"
      log_info "$(l10n "Selected release asset: ${ASSET_NAME}" "已选择发布文件：${ASSET_NAME}")"
      return
    fi
  done

  log_error "$(l10n "No compatible Linux asset was found for architecture $(uname -m)." "找不到适用于 $(uname -m) 架构的 Linux 发布文件。")"
  exit 1
}

download_and_verify_release() {
  local archive_path
  local checksum_path

  TMP_DIR=$(mktemp -d)
  archive_path="${TMP_DIR}/${ASSET_NAME}"
  checksum_path="${TMP_DIR}/${ASSET_NAME}.sha256"

  log_info "$(l10n "Downloading ${ASSET_NAME}" "正在下载 ${ASSET_NAME}")"
  curl -fL --progress-bar -o "${archive_path}" "${ASSET_URL}"
  curl -fL --progress-bar -o "${checksum_path}" "${SHA256_URL}"

  log_info "$(l10n "Verifying archive checksum" "正在校验压缩包 SHA256")"
  (
    cd "${TMP_DIR}"
    sha256sum -c "${ASSET_NAME}.sha256"
  )

  log_info "$(l10n "Extracting archive" "正在解压发布文件")"
  tar -xJf "${archive_path}" -C "${TMP_DIR}"
}

install_binaries() {
  local binary
  local binary_path

  for binary in ssserver ssservice; do
    binary_path=$(find_release_binary "${binary}")

    install -m 0755 "${binary_path}" "${BIN_DIR}/${binary}"
  done
}

ensure_supported_method() {
  while ! "${BIN_DIR}/ssservice" genkey -m "${METHOD}" >/dev/null 2>&1; do
    log_warn "$(l10n "The installed ssservice build does not accept method: ${METHOD}" "已安装的 ssservice 不支持加密方法：${METHOD}")"
    METHOD=$(select_method)
  done

  if [[ -n "${PASSWORD}" ]] && ! validate_password_for_method "${METHOD}" "${PASSWORD}"; then
    log_warn "$(l10n "The custom password/key must be replaced after selecting method: ${METHOD}" "选择 ${METHOD} 后必须重新设置密码/key。")"
    PASSWORD=$(prompt_password "${METHOD}")
  fi
}

ensure_service_account() {
  local nologin_shell

  if ! getent group "${SERVICE_USER}" >/dev/null 2>&1; then
    groupadd --system "${SERVICE_USER}"
    ensure_state_dir
    : >"${GROUP_MARKER_PATH}"
  fi

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    nologin_shell=$(command -v nologin || printf '%s' "/usr/sbin/nologin")
    useradd \
      --system \
      --gid "${SERVICE_USER}" \
      --home-dir "${CONFIG_DIR}" \
      --shell "${nologin_shell}" \
      --comment "Shadowsocks-rust service user" \
      "${SERVICE_USER}"
    ensure_state_dir
    : >"${USER_MARKER_PATH}"
  fi
}

ensure_state_dir() {
  mkdir -p "${STATE_DIR}" || return 1
  chmod 0700 "${STATE_DIR}" || return 1
}

write_server_config() {
  local rendered_password
  local backup_path=""
  local staged_path=""

  mkdir -p "${CONFIG_DIR}"
  chown root:"${SERVICE_USER}" "${CONFIG_DIR}"
  chmod 0750 "${CONFIG_DIR}"

  if [[ -f "${CONFIG_PATH}" ]]; then
    backup_path=$(next_backup_path "${CONFIG_PATH}")
    cp -a "${CONFIG_PATH}" "${backup_path}"
    log_warn "$(l10n "Existing configuration backed up to ${backup_path}" "现有配置已备份至 ${backup_path}")"
  fi

  if [[ -z "${PASSWORD}" ]]; then
    PASSWORD=$("${BIN_DIR}/ssservice" genkey -m "${METHOD}" | tail -n1 | tr -d '\r')
    if [[ -z "${PASSWORD}" ]]; then
      log_error "$(l10n "Failed to generate a password/key with ssservice genkey." "无法使用 ssservice genkey 生成密码/key。")"
      exit 1
    fi
  fi

  rendered_password=$(json_escape "${PASSWORD}")

  staged_path=$(mktemp "${CONFIG_DIR}/.config.install.XXXXXX")
  cat >"${staged_path}" <<EOF
{
  "server": "$(json_escape "${LISTEN_ADDRESS}")",
  "server_port": ${SERVER_PORT},
  "password": "${rendered_password}",
  "method": "$(json_escape "${METHOD}")",
  "mode": "$(json_escape "${MODE}")",
  "timeout": ${TIMEOUT_SECONDS}
}
EOF

  validate_server_config "${staged_path}"
  chmod 0640 "${staged_path}"
  chown root:"${SERVICE_USER}" "${staged_path}"
  mv -f "${staged_path}" "${CONFIG_PATH}"

  ensure_state_dir
  printf '%s\n' "${CONFIG_NAME}" >"${CONFIG_NAME_PATH}"
  chmod 0600 "${CONFIG_NAME_PATH}"
}

write_systemd_unit() {
  local backup_path=""
  local staged_path=""

  if [[ -L "${SERVICE_PATH}" ]]; then
    log_error "$(l10n "Refusing to replace a symbolic-link service unit: ${SERVICE_PATH}" "拒绝替换符号链接形式的服务单元：${SERVICE_PATH}")"
    return 1
  fi

  if [[ -f "${SERVICE_PATH}" ]]; then
    backup_path=$(next_backup_path "${SERVICE_PATH}")
    cp -a "${SERVICE_PATH}" "${backup_path}"
    log_warn "$(l10n "Existing service file backed up to ${backup_path}" "现有服务文件已备份至 ${backup_path}")"
  fi

  staged_path=$(mktemp "${SERVICE_PATH%/*}/.${SERVICE_NAME}.service.XXXXXX")
  if ! cat >"${staged_path}" <<EOF
[Unit]
Description=Shadowsocks-rust Server Service
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BIN_DIR}/ssserver -c ${CONFIG_PATH}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectHome=true
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  then
    rm -f "${staged_path}"
    return 1
  fi

  if ! chmod 0644 "${staged_path}" || ! mv -f "${staged_path}" "${SERVICE_PATH}"; then
    rm -f "${staged_path}"
    return 1
  fi
}

maybe_open_firewall() {
  local changed="n"

  FIREWALL_TCP_CHANGED="n"
  FIREWALL_UDP_CHANGED="n"
  FIREWALLD_ZONE=""

  if [[ "${OPEN_FIREWALL}" != "y" ]]; then
    return
  fi

  case "${FIREWALL_MANAGER}" in
    firewalld)
      FIREWALLD_ZONE=$(resolve_firewalld_zone) || return 1
      if open_firewall_rule firewalld "${SERVER_PORT}" tcp "${FIREWALLD_ZONE}"; then
        FIREWALL_TCP_CHANGED="${FIREWALL_RULE_CHANGED}"
        if [[ "${FIREWALL_RULE_CHANGED}" == "y" ]]; then
          changed="y"
        fi
      else
        FIREWALL_TCP_CHANGED="${FIREWALL_RULE_CHANGED}"
        return 1
      fi
      if open_firewall_rule firewalld "${SERVER_PORT}" udp "${FIREWALLD_ZONE}"; then
        FIREWALL_UDP_CHANGED="${FIREWALL_RULE_CHANGED}"
        if [[ "${FIREWALL_RULE_CHANGED}" == "y" ]]; then
          changed="y"
        fi
      else
        FIREWALL_UDP_CHANGED="${FIREWALL_RULE_CHANGED}"
        return 1
      fi
      if [[ "${changed}" == "y" ]] && ! firewall-cmd --reload; then
        log_error "$(l10n "firewalld could not reload. Ownership records were retained for cleanup." "firewalld 重新加载失败，已保留规则所有权记录以便清理。")"
        return 1
      fi
      ;;
    ufw)
      if open_firewall_rule ufw "${SERVER_PORT}" tcp; then
        FIREWALL_TCP_CHANGED="${FIREWALL_RULE_CHANGED}"
      else
        FIREWALL_TCP_CHANGED="${FIREWALL_RULE_CHANGED}"
        return 1
      fi
      if open_firewall_rule ufw "${SERVER_PORT}" udp; then
        FIREWALL_UDP_CHANGED="${FIREWALL_RULE_CHANGED}"
      else
        FIREWALL_UDP_CHANGED="${FIREWALL_RULE_CHANGED}"
        return 1
      fi
      ;;
    *)
      log_warn "$(l10n "Firewall auto-open is not supported on this host. Open TCP/UDP ${SERVER_PORT} manually." "当前主机不支持自动配置防火墙，请手动放行 TCP/UDP ${SERVER_PORT}。")"
      ;;
  esac

}

open_firewall_rule() {
  local manager="$1"
  local port="$2"
  local protocol="$3"
  local zone="${4:-}"
  local query_status=0
  local rule_state=""

  FIREWALL_RULE_CHANGED="n"

  case "${manager}" in
    firewalld)
      zone=$(resolve_firewalld_zone "${zone}") || return 1
      if firewall-cmd --zone="${zone}" --permanent --query-port="${port}/${protocol}" >/dev/null 2>&1; then
        return 0
      else
        query_status=$?
      fi
      if (( query_status != 1 )); then
        log_error "$(l10n "Could not query firewalld rule ${port}/${protocol}." "无法查询 firewalld 规则 ${port}/${protocol}。")"
        return 1
      fi
      set_firewall_rule_record_state "${manager}" "${port}" "${protocol}" pending "${zone}" || return 1
      if ! firewall-cmd --zone="${zone}" --permanent --add-port="${port}/${protocol}"; then
        log_error "$(l10n "Could not add firewalld rule ${port}/${protocol}. A pending record was retained for retry." "无法添加 firewalld 规则 ${port}/${protocol}，已保留待重试记录。")"
        return 1
      fi
      FIREWALL_RULE_CHANGED="y"
      if ! set_firewall_rule_record_state "${manager}" "${port}" "${protocol}" owned "${zone}"; then
        log_error "$(l10n "The firewalld rule was added, but its ownership state could not be finalized." "firewalld 规则已添加，但无法完成所有权状态写入。")"
        if delete_managed_firewall_rule "${manager}" "${port}" "${protocol}" "${zone}"; then
          FIREWALL_RULE_CHANGED="n"
        fi
        return 1
      fi
      ;;
    ufw)
      rule_state=$(query_ufw_rule_state "${port}" "${protocol}") || return 1
      if [[ "${rule_state}" == "present" ]]; then
        return 0
      fi
      set_firewall_rule_record_state "${manager}" "${port}" "${protocol}" pending || return 1
      if ! ufw allow "${port}/${protocol}"; then
        log_error "$(l10n "Could not add ufw rule ${port}/${protocol}. A pending record was retained for retry." "无法添加 ufw 规则 ${port}/${protocol}，已保留待重试记录。")"
        return 1
      fi
      FIREWALL_RULE_CHANGED="y"
      if ! set_firewall_rule_record_state "${manager}" "${port}" "${protocol}" owned; then
        log_error "$(l10n "The ufw rule was added, but its ownership state could not be finalized." "ufw 规则已添加，但无法完成所有权状态写入。")"
        if delete_managed_firewall_rule "${manager}" "${port}" "${protocol}"; then
          FIREWALL_RULE_CHANGED="n"
        fi
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

query_ufw_rule_state() {
  local port="$1"
  local protocol="$2"
  local output=""

  if ! output=$(LC_ALL=C ufw status 2>/dev/null); then
    log_error "$(l10n "Could not query ufw status." "无法查询 ufw 状态。")"
    return 1
  fi

  if ! printf '%s\n' "${output}" | grep -Eqi '^Status:[[:space:]]+active([[:space:]]|$)'; then
    log_error "$(l10n "ufw is not active, so its persistent rule state cannot be verified safely." "ufw 未启用，无法安全确认其持久规则状态。")"
    return 1
  fi

  if printf '%s\n' "${output}" | sed -E 's/[[:space:]]+/ /g' | grep -Eq "^${port}/${protocol} .*ALLOW"; then
    printf '%s' "present"
  else
    printf '%s' "absent"
  fi
}

resolve_firewalld_zone() {
  local zone="${1:-}"

  if [[ -z "${zone}" ]]; then
    if ! zone=$(firewall-cmd --get-default-zone 2>/dev/null); then
      log_error "$(l10n "Could not determine the firewalld default zone." "无法确定 firewalld 默认 zone。")"
      return 1
    fi
  fi
  if [[ -z "${zone}" || ! "${zone}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    log_error "$(l10n "Invalid firewalld zone: ${zone:-empty}." "firewalld zone 无效：${zone:-空}。")"
    return 1
  fi
  printf '%s' "${zone}"
}

set_firewall_rule_record_state() {
  local manager="$1"
  local port="$2"
  local protocol="$3"
  local ownership="$4"
  local zone="${5:-}"
  local -a state_lines=()
  local entry_manager=""
  local entry_port=""
  local entry_protocol=""
  local entry_ownership=""
  local entry_zone=""
  local entry_extra=""
  local found="n"
  local line=""
  local staged_path=""

  case "${manager}|${port}|${protocol}|${ownership}" in
    firewalld\|*\|tcp\|pending|firewalld\|*\|tcp\|owned|firewalld\|*\|tcp\|cleanup-needed|firewalld\|*\|tcp\|deleting|firewalld\|*\|udp\|pending|firewalld\|*\|udp\|owned|firewalld\|*\|udp\|cleanup-needed|firewalld\|*\|udp\|deleting|ufw\|*\|tcp\|pending|ufw\|*\|tcp\|owned|ufw\|*\|tcp\|cleanup-needed|ufw\|*\|tcp\|deleting|ufw\|*\|udp\|pending|ufw\|*\|udp\|owned|ufw\|*\|udp\|cleanup-needed|ufw\|*\|udp\|deleting) ;;
    *) return 1 ;;
  esac
  if [[ ! "${port}" =~ ^[0-9]{1,5}$ ]] || (( 10#${port} < 1 || 10#${port} > 65535 )); then
    return 1
  fi
  if [[ "${manager}" == "firewalld" ]]; then
    zone=$(resolve_firewalld_zone "${zone}") || return 1
  elif [[ -n "${zone}" ]]; then
    return 1
  fi
  if ! ensure_state_dir || [[ -L "${FIREWALL_STATE_PATH}" ]]; then
    return 1
  fi
  if [[ -f "${FIREWALL_STATE_PATH}" ]] && ! mapfile -t state_lines <"${FIREWALL_STATE_PATH}"; then
    return 1
  fi
  if ! staged_path=$(mktemp "${STATE_DIR}/.firewall-rule.XXXXXX"); then
    return 1
  fi
  if ! chmod 0600 "${staged_path}"; then
    rm -f "${staged_path}" || true
    return 1
  fi

  for line in "${state_lines[@]}"; do
      IFS='|' read -r entry_manager entry_port entry_protocol entry_ownership entry_zone entry_extra <<<"${line}"
      if [[ -z "${entry_extra}" && "${entry_manager}" == "${manager}" && "${entry_port}" == "${port}" && "${entry_protocol}" == "${protocol}" && ( -z "${entry_ownership}" || "${entry_ownership}" == "pending" || "${entry_ownership}" == "owned" || "${entry_ownership}" == "cleanup-needed" || "${entry_ownership}" == "deleting" ) && ( ( "${manager}" == "firewalld" && "${entry_zone}" == "${zone}" ) || ( "${manager}" != "firewalld" && -z "${entry_zone}" ) ) ]]; then
        if [[ "${found}" == "n" ]]; then
          if ! write_firewall_rule_record "${staged_path}" "${manager}" "${port}" "${protocol}" "${ownership}" "${zone}"; then
            rm -f "${staged_path}" || true
            return 1
          fi
          found="y"
        fi
      else
        if ! printf '%s\n' "${line}" >>"${staged_path}"; then
          rm -f "${staged_path}" || true
          return 1
        fi
      fi
  done

  if [[ "${found}" == "n" ]]; then
    if ! write_firewall_rule_record "${staged_path}" "${manager}" "${port}" "${protocol}" "${ownership}" "${zone}"; then
      rm -f "${staged_path}" || true
      return 1
    fi
  fi
  if ! mv -f "${staged_path}" "${FIREWALL_STATE_PATH}"; then
    rm -f "${staged_path}" || true
    return 1
  fi
}

write_firewall_rule_record() {
  local output_path="$1"
  local manager="$2"
  local port="$3"
  local protocol="$4"
  local ownership="$5"
  local zone="${6:-}"

  if [[ "${manager}" == "firewalld" ]]; then
    printf '%s|%s|%s|%s|%s\n' "${manager}" "${port}" "${protocol}" "${ownership}" "${zone}" >>"${output_path}"
  else
    printf '%s|%s|%s|%s\n' "${manager}" "${port}" "${protocol}" "${ownership}" >>"${output_path}"
  fi
}

discard_firewall_rule_record() {
  local target_manager="$1"
  local target_port="$2"
  local target_protocol="$3"
  local target_ownership="${4:-pending}"
  local target_zone="${5:-}"
  local -a state_lines=()
  local manager=""
  local port=""
  local protocol=""
  local ownership=""
  local zone=""
  local extra=""
  local staged_path=""

  [[ -f "${FIREWALL_STATE_PATH}" ]] || return 0
  if [[ -L "${FIREWALL_STATE_PATH}" ]] || ! mapfile -t state_lines <"${FIREWALL_STATE_PATH}"; then
    return 1
  fi
  if ! staged_path=$(mktemp "${STATE_DIR}/.firewall-rule.XXXXXX"); then
    return 1
  fi
  if ! chmod 0600 "${staged_path}"; then
    rm -f "${staged_path}" || true
    return 1
  fi

  for line in "${state_lines[@]}"; do
    IFS='|' read -r manager port protocol ownership zone extra <<<"${line}"
    if is_valid_firewall_rule_record "${manager}" "${port}" "${protocol}" "${ownership}" "${zone}" "${extra}" && [[ "${manager}" == "${target_manager}" && "${port}" == "${target_port}" && "${protocol}" == "${target_protocol}" && ( "${target_ownership}" == "any" || "${ownership}" == "${target_ownership}" ) && ( "${manager}" != "firewalld" || "${zone}" == "${target_zone}" ) ]]; then
      continue
    fi
    if ! printf '%s\n' "${line}" >>"${staged_path}"; then
      rm -f "${staged_path}" || true
      return 1
    fi
  done

  if [[ -s "${staged_path}" ]]; then
    if ! mv -f "${staged_path}" "${FIREWALL_STATE_PATH}"; then
      rm -f "${staged_path}" || true
      return 1
    fi
  else
    if ! mv -f "${staged_path}" "${FIREWALL_STATE_PATH}"; then
      rm -f "${staged_path}" || true
      return 1
    fi
    rm -f "${FIREWALL_STATE_PATH}" || return 1
  fi
}

has_owned_firewall_rules_for_port() {
  local target_port="$1"
  local manager=""
  local port=""
  local protocol=""
  local ownership=""
  local zone=""
  local extra=""

  [[ -f "${FIREWALL_STATE_PATH}" ]] || return 1
  while IFS='|' read -r manager port protocol ownership zone extra; do
    if is_valid_firewall_rule_record "${manager}" "${port}" "${protocol}" "${ownership}" "${zone}" "${extra}" && [[ "${port}" == "${target_port}" && ( -z "${ownership}" || "${ownership}" == "owned" || "${ownership}" == "cleanup-needed" || "${ownership}" == "deleting" ) ]]; then
      return 0
    fi
  done <"${FIREWALL_STATE_PATH}"
  return 1
}

remove_recorded_firewall_rule() {
  local filter_port="${1:-}"
  local -a state_lines=()
  local failed="n"
  local manager=""
  local port=""
  local protocol=""
  local ownership=""
  local zone=""
  local extra=""
  local line=""
  local normalized_ownership=""
  local rule_state=""

  if [[ ! -f "${FIREWALL_STATE_PATH}" ]]; then
    return 0
  fi

  if [[ -L "${FIREWALL_STATE_PATH}" ]] || ! mapfile -t state_lines <"${FIREWALL_STATE_PATH}"; then
    return 1
  fi

  for line in "${state_lines[@]}"; do
    manager=""
    port=""
    protocol=""
    ownership=""
    zone=""
    extra=""
    IFS='|' read -r manager port protocol ownership zone extra <<<"${line}"
    if ! is_valid_firewall_rule_record "${manager}" "${port}" "${protocol}" "${ownership}" "${zone}" "${extra}"; then
      failed="y"
      continue
    fi
    normalized_ownership="${ownership:-owned}"
    if [[ -n "${filter_port}" && "${port}" != "${filter_port}" ]]; then
      continue
    fi
    if [[ "${normalized_ownership}" == "pending" ]]; then
      if rule_state=$(query_firewall_rule_state "${manager}" "${port}" "${protocol}" "${zone}"); then
        if [[ "${rule_state}" == "absent" ]]; then
          if ! discard_firewall_rule_record "${manager}" "${port}" "${protocol}" pending "${zone}"; then
            failed="y"
          fi
          continue
        fi
      fi
      failed="y"
      continue
    fi
    if [[ "${normalized_ownership}" == "deleting" ]]; then
      if rule_state=$(query_firewall_rule_state "${manager}" "${port}" "${protocol}" "${zone}") && [[ "${rule_state}" == "absent" ]]; then
        if [[ "${manager}" != "firewalld" ]] || firewall-cmd --reload >/dev/null 2>&1; then
          if ! discard_firewall_rule_record "${manager}" "${port}" "${protocol}" deleting "${zone}"; then
            failed="y"
          fi
          continue
        fi
      fi
      failed="y"
      continue
    fi
    if ! delete_managed_firewall_rule "${manager}" "${port}" "${protocol}" "${zone}"; then
      failed="y"
    fi
  done

  [[ "${failed}" == "n" ]]
}

is_valid_firewall_rule_record() {
  local manager="$1"
  local port="$2"
  local protocol="$3"
  local ownership="$4"
  local zone="$5"
  local extra="$6"

  [[ -z "${extra}" ]] || return 1
  [[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#${port} >= 1 && 10#${port} <= 65535 )) || return 1
  [[ "${protocol}" == "tcp" || "${protocol}" == "udp" ]] || return 1
  [[ -z "${ownership}" || "${ownership}" == "pending" || "${ownership}" == "owned" || "${ownership}" == "cleanup-needed" || "${ownership}" == "deleting" ]] || return 1

  case "${manager}" in
    firewalld)
      [[ -n "${ownership}" && -n "${zone}" && "${zone}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
      ;;
    ufw)
      [[ -z "${zone}" ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

cleanup_firewall_rules_for_failed_change() {
  local manager="$1"
  local port="$2"
  local tcp_changed="$3"
  local udp_changed="$4"
  local zone="${5:-}"
  local failed="n"
  local changed=""
  local protocol=""

  for protocol in tcp udp; do
    if [[ "${protocol}" == "tcp" ]]; then
      changed="${tcp_changed}"
    else
      changed="${udp_changed}"
    fi
    [[ "${changed}" == "y" ]] || continue

    if ! delete_managed_firewall_rule "${manager}" "${port}" "${protocol}" "${zone}"; then
      failed="y"
    fi
  done

  if [[ "${failed}" == "y" ]]; then
    log_warn "$(l10n "Some newly prepared firewall rules for port ${port} could not be rolled back; their ownership records were retained." "为端口 ${port} 新准备的部分防火墙规则无法回滚，已保留所有权记录。")"
  fi
  return 0
}

delete_managed_firewall_rule() {
  local manager="$1"
  local port="$2"
  local protocol="$3"
  local zone="${4:-}"
  local rule_state=""

  rule_state=$(query_firewall_rule_state "${manager}" "${port}" "${protocol}" "${zone}") || return 1
  if ! set_firewall_rule_record_state "${manager}" "${port}" "${protocol}" deleting "${zone}"; then
    return 1
  fi
  if ! remove_firewall_rule "${manager}" "${port}" "${protocol}" "${zone}"; then
    return 1
  fi
  discard_firewall_rule_record "${manager}" "${port}" "${protocol}" deleting "${zone}"
}

remove_firewall_rule() {
  local manager="$1"
  local port="$2"
  local protocol="$3"
  local zone="${4:-}"
  local rule_state=""

  if [[ "${manager}" == "firewalld" ]]; then
    zone=$(resolve_firewalld_zone "${zone}") || return 1
  fi
  rule_state=$(query_firewall_rule_state "${manager}" "${port}" "${protocol}" "${zone}") || return 1

  case "${manager}" in
    firewalld)
      if [[ "${rule_state}" == "present" ]]; then
        firewall-cmd --zone="${zone}" --permanent --remove-port="${port}/${protocol}" >/dev/null 2>&1 || return 1
      fi
      # The permanent rule may already be gone after an earlier reload failure.
      # Retry the reload before releasing ownership of the runtime rule.
      firewall-cmd --reload >/dev/null 2>&1 || return 1
      ;;
    ufw)
      if [[ "${rule_state}" == "absent" ]]; then
        return 0
      fi
      ufw --force delete allow "${port}/${protocol}" >/dev/null 2>&1 || return 1
      rule_state=$(query_firewall_rule_state "${manager}" "${port}" "${protocol}") || return 1
      [[ "${rule_state}" == "absent" ]] || return 1
      ;;
    *)
      return 0
      ;;
  esac
}

query_firewall_rule_state() {
  local manager="$1"
  local port="$2"
  local protocol="$3"
  local zone="${4:-}"
  local query_status=0

  case "${manager}" in
    firewalld)
      command -v firewall-cmd >/dev/null 2>&1 || return 1
      zone=$(resolve_firewalld_zone "${zone}") || return 1
      if firewall-cmd --zone="${zone}" --permanent --query-port="${port}/${protocol}" >/dev/null 2>&1; then
        printf '%s' present
        return 0
      else
        query_status=$?
      fi
      if (( query_status == 1 )); then
        printf '%s' absent
        return 0
      fi
      return 1
      ;;
    ufw)
      command -v ufw >/dev/null 2>&1 || return 1
      query_ufw_rule_state "${port}" "${protocol}"
      ;;
    *)
      return 1
      ;;
  esac
}

enable_and_restart_service() {
  log_info "$(l10n "Reloading systemd and starting ${SERVICE_NAME}" "正在重新加载 systemd 并启动 ${SERVICE_NAME}")"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  if ! restart_and_verify_service; then
    systemctl --no-pager --full status "${SERVICE_NAME}" || true
    if command -v journalctl >/dev/null 2>&1; then
      journalctl -u "${SERVICE_NAME}" --no-pager -n 40 || true
    fi
    log_error "$(l10n "${SERVICE_NAME} failed to start." "${SERVICE_NAME} 启动失败。")"
    exit 1
  fi

  systemctl --no-pager --full status "${SERVICE_NAME}" | sed -n '1,12p'
}

detect_firewall_manager() {
  FIREWALL_MANAGER=""

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FIREWALL_MANAGER="firewalld"
    return
  fi

  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -qi '^status: active'; then
    FIREWALL_MANAGER="ufw"
  fi
}

asset_candidates() {
  local version="$1"
  local arch
  local libc

  arch=$(normalize_arch "$(uname -m)")
  libc=$(detect_libc)

  case "${arch}" in
    x86_64)
      target_candidates "${version}" "${arch}" "${libc}" \
        "x86_64-unknown-linux-musl" \
        "x86_64-unknown-linux-gnu"
      ;;
    aarch64)
      target_candidates "${version}" "${arch}" "${libc}" \
        "aarch64-unknown-linux-musl" \
        "aarch64-unknown-linux-gnu"
      ;;
    armv7)
      target_candidates "${version}" "${arch}" "${libc}" \
        "armv7-unknown-linux-musleabihf" \
        "armv7-unknown-linux-gnueabihf" \
        "arm-unknown-linux-musleabihf" \
        "arm-unknown-linux-gnueabihf"
      ;;
    arm)
      target_candidates "${version}" "${arch}" "${libc}" \
        "arm-unknown-linux-musleabihf" \
        "arm-unknown-linux-gnueabihf" \
        "arm-unknown-linux-musleabi" \
        "arm-unknown-linux-gnueabi"
      ;;
    i686)
      target_candidates "${version}" "${arch}" "${libc}" \
        "i686-unknown-linux-musl"
      ;;
    loongarch64)
      target_candidates "${version}" "${arch}" "${libc}" \
        "loongarch64-unknown-linux-musl" \
        "loongarch64-unknown-linux-gnu"
      ;;
    mips)
      target_candidates "${version}" "${arch}" "${libc}" \
        "mips-unknown-linux-gnu"
      ;;
    mipsel)
      target_candidates "${version}" "${arch}" "${libc}" \
        "mipsel-unknown-linux-gnu"
      ;;
    mips64el)
      target_candidates "${version}" "${arch}" "${libc}" \
        "mips64el-unknown-linux-gnuabi64"
      ;;
    riscv64gc)
      target_candidates "${version}" "${arch}" "${libc}" \
        "riscv64gc-unknown-linux-musl" \
        "riscv64gc-unknown-linux-gnu"
      ;;
    *)
      return 1
      ;;
  esac
}

target_candidates() {
  local version="$1"
  local arch="$2"
  local libc="$3"
  shift 3

  local -a triples=("$@")
  local triple

  if [[ "${libc}" == "gnu" ]]; then
    for triple in "${triples[@]}"; do
      if [[ "${triple}" == *"-gnu"* ]]; then
        printf 'shadowsocks-%s.%s.tar.xz\n' "${version}" "${triple}"
      fi
    done
    for triple in "${triples[@]}"; do
      if [[ "${triple}" == *"-musl"* ]]; then
        printf 'shadowsocks-%s.%s.tar.xz\n' "${version}" "${triple}"
      fi
    done
  else
    for triple in "${triples[@]}"; do
      if [[ "${triple}" == *"-musl"* ]]; then
        printf 'shadowsocks-%s.%s.tar.xz\n' "${version}" "${triple}"
      fi
    done
    for triple in "${triples[@]}"; do
      if [[ "${triple}" == *"-gnu"* ]]; then
        printf 'shadowsocks-%s.%s.tar.xz\n' "${version}" "${triple}"
      fi
    done
  fi

  if [[ "${arch}" == "arm" ]]; then
    printf 'shadowsocks-%s.armv7-unknown-linux-musleabihf.tar.xz\n' "${version}"
    printf 'shadowsocks-%s.armv7-unknown-linux-gnueabihf.tar.xz\n' "${version}"
  fi
}

asset_url_from_release() {
  local asset_name="$1"
  printf '%s\n' "${RELEASE_JSON}" | sed -nE 's/^[[:space:]]*"browser_download_url":[[:space:]]*"([^"]+)".*/\1/p' | grep -F "/${asset_name}" | grep -F -x "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${INSTALL_VERSION}/${asset_name}" | head -n1
}

normalize_arch() {
  case "$1" in
    x86_64|amd64) printf '%s' "x86_64" ;;
    aarch64|arm64) printf '%s' "aarch64" ;;
    armv7l|armv7) printf '%s' "armv7" ;;
    armv6l|armv6|armhf|arm) printf '%s' "arm" ;;
    i386|i686) printf '%s' "i686" ;;
    loongarch64) printf '%s' "loongarch64" ;;
    mips) printf '%s' "mips" ;;
    mipsel) printf '%s' "mipsel" ;;
    mips64el) printf '%s' "mips64el" ;;
    riscv64|riscv64gc) printf '%s' "riscv64gc" ;;
    *)
      log_error "$(l10n "Unsupported architecture: $1" "不支持的系统架构：$1")"
      exit 1
      ;;
  esac
}

detect_libc() {
  local ldd_output=""

  if command -v ldd >/dev/null 2>&1; then
    ldd_output=$(ldd --version 2>&1 || true)
  fi

  if printf '%s' "${ldd_output}" | grep -qi 'musl'; then
    printf '%s' "musl"
  else
    printf '%s' "gnu"
  fi
}

normalize_version() {
  local version="$1"
  if [[ "${version}" != v* ]]; then
    version="v${version}"
  fi
  printf '%s' "${version}"
}

validate_port() {
  local port="$1"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    log_error "$(l10n "Port must be an integer between 1 and 65535." "端口必须是 1 到 65535 之间的整数。")"
    return 1
  fi
}

validate_timeout() {
  local value="$1"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    log_error "$(l10n "Timeout must be a positive integer." "超时时间必须是正整数。")"
    return 1
  fi
}

validate_mode() {
  case "$1" in
    tcp_only|udp_only|tcp_and_udp) ;;
    *)
      log_error "$(l10n "Mode must be one of: tcp_only, udp_only, tcp_and_udp." "流量模式必须是 tcp_only、udp_only 或 tcp_and_udp。")"
      return 1
      ;;
  esac
}

password_key_bytes() {
  case "$1" in
    2022-blake3-aes-128-gcm)
      printf '%s' "16"
      ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      printf '%s' "32"
      ;;
  esac
}

validate_password_for_method() {
  local method="$1"
  local password="$2"
  local expected_bytes=""
  local expected_base64_length=0
  local expected_padding=0
  local normalized=""
  local padding=""
  local decode_value=""
  local canonical=""

  if [[ -z "${password}" ]]; then
    log_warn "$(l10n "Custom password/key cannot be empty. Leave the prompt blank to generate a random value." "自定义密码/key 不能为空；在输入提示处留空可生成随机值。")"
    return 1
  fi

  if [[ "${password}" =~ [[:cntrl:]] ]]; then
    log_warn "$(l10n "Password/key cannot contain control characters." "密码/key 不能包含控制字符。")"
    return 1
  fi

  expected_bytes=$(password_key_bytes "${method}")
  if [[ -z "${expected_bytes}" ]]; then
    if [[ "${method}" == 2022-* ]]; then
      log_warn "$(l10n "Custom key validation is not available for AEAD 2022 method: ${method}. Leave it blank to generate a random key." "无法验证 AEAD 2022 加密方法 ${method} 的自定义 key，请留空生成随机 key。")"
      return 1
    fi
    return 0
  fi

  if [[ ! "${password}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    log_warn "$(l10n "${method} requires a standard Base64 key that decodes to exactly ${expected_bytes} bytes." "${method} 需要标准 Base64 key，解码后必须恰好为 ${expected_bytes} 字节。")"
    return 1
  fi

  normalized=${password%%=*}
  padding=${password#"${normalized}"}
  expected_base64_length=$(( (expected_bytes * 8 + 5) / 6 ))
  if (( ${#normalized} != expected_base64_length )); then
    log_warn "$(l10n "${method} requires a standard Base64 key that decodes to exactly ${expected_bytes} bytes." "${method} 需要标准 Base64 key，解码后必须恰好为 ${expected_bytes} 字节。")"
    return 1
  fi

  expected_padding=$(( (4 - expected_base64_length % 4) % 4 ))
  if (( ${#padding} > expected_padding )); then
    log_warn "$(l10n "${method} has invalid Base64 padding." "${method} 的 Base64 填充无效。")"
    return 1
  fi

  decode_value=${password}
  while (( ${#decode_value} % 4 != 0 )); do
    decode_value+='='
  done

  if ! canonical=$(printf '%s' "${decode_value}" | base64 -d 2>/dev/null | base64 | tr -d '\n='); then
    log_warn "$(l10n "${method} requires a valid standard Base64 key." "${method} 需要有效的标准 Base64 key。")"
    return 1
  fi

  if [[ "${canonical}" != "${normalized}" ]]; then
    log_warn "$(l10n "${method} requires a canonical standard Base64 key." "${method} 需要规范的标准 Base64 key。")"
    return 1
  fi

  return 0
}

prompt_password() {
  local method="$1"
  local reply=""

  while true; do
    if ! read -r -s -p "$(l10n "Password/key (blank = generate a random value)" "密码/key（留空 = 生成随机值）"): " reply; then
      printf '\n' >&2
      log_error "$(l10n "Password/key input was interrupted." "密码/key 输入被中断。")"
      return 1
    fi
    printf '\n' >&2

    if [[ -z "${reply}" ]]; then
      printf '%s' ""
      return 0
    fi

    if validate_password_for_method "${method}" "${reply}"; then
      printf '%s' "${reply}"
      return 0
    fi

    log_warn "$(l10n "Invalid password/key. Please try again, or leave it blank for a random value." "密码/key 无效，请重试，或留空生成随机值。")"
  done
}

prompt_default() {
  local label="$1"
  local default_value="$2"
  local reply=""

  if [[ -n "${default_value}" ]]; then
    read -r -p "${label} [${default_value}]: " reply
  else
    read -r -p "${label}: " reply
  fi

  if [[ -z "${reply}" ]]; then
    printf '%s' "${default_value}"
  else
    printf '%s' "${reply}"
  fi
}

listen_address_prompt() {
  local default_value="$1"

  if [[ "${default_value}" == "${DEFAULT_BIND_ADDRESS}" ]]; then
    l10n \
      "Listen address (IP address or network interface; press Enter for all interfaces) [${default_value}]:" \
      "监听地址（IP 地址或网卡接口；按回车键监听所有接口） [${default_value}]："
  else
    l10n \
      "Listen address (IP address or network interface; press Enter to keep the current value) [${default_value}]:" \
      "监听地址（IP 地址或网卡接口；按回车键保留当前值） [${default_value}]："
  fi
}

prompt_listen_address() {
  local default_value="$1"
  local reply=""

  read -r -p "$(listen_address_prompt "${default_value}") " reply

  if [[ -z "${reply}" ]]; then
    printf '%s' "${default_value}"
  else
    printf '%s' "${reply}"
  fi
}

select_method() {
  local choice=""
  local manual_method=""
  local index=1
  local entry=""
  local method=""
  local description=""
  local translations=""
  local manual_option=0

  while true; do
    printf '\n%s\n' "$(l10n "Common cipher methods supported by Shadowsocks-rust:" "Shadowsocks-rust 常用加密方法：")" >&2
    index=1
    for entry in "${COMMON_METHODS[@]}"; do
      method=${entry%%|*}
      translations=${entry#*|}
      description=${translations%%|*}
      if [[ "${SCRIPT_LANG:-en}" == "zh" ]]; then
        description=${translations#*|}
      fi
      printf '  %d) %s\n     %s\n' "${index}" "${method}" "${description}" >&2
      index=$((index + 1))
    done
    manual_option=${index}
    printf '  %d) %s\n' "${manual_option}" "$(l10n "Manual input" "手动输入")" >&2

    read -r -p "$(l10n "Select cipher method" "请选择加密方法") [1]: " choice
    choice=${choice:-1}

    if [[ "${choice}" =~ ^[0-9]+$ ]]; then
      if (( choice >= 1 && choice < manual_option )); then
        printf '%s' "${COMMON_METHODS[choice-1]%%|*}"
        return 0
      fi

      if (( choice == manual_option )); then
        read -r -p "$(l10n "Enter a cipher method exactly as supported by Shadowsocks-rust" "请输入 Shadowsocks-rust 支持的准确加密方法名称"): " manual_method
        manual_method=$(printf '%s' "${manual_method}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [[ -n "${manual_method}" ]]; then
          printf '%s' "${manual_method}"
          return 0
        fi
      fi
    fi

    log_warn "$(l10n "Invalid selection. Please choose one of the listed numbers." "选择无效，请输入菜单中的数字。")"
  done
}

prompt_yes_no() {
  local label="$1"
  local default_choice="$2"
  local reply=""

  if [[ "${default_choice}" == "y" ]]; then
    if ! read -r -p "${label} [Y/n]: " reply; then
      reply="y"
    fi
    reply=${reply:-y}
  else
    if ! read -r -p "${label} [y/N]: " reply; then
      reply="n"
    fi
    reply=${reply:-n}
  fi

  reply=$(printf '%s' "${reply}" | tr '[:upper:]' '[:lower:]')
  case "${reply}" in
    y|yes|是|是的) printf '%s' "y" ;;
    n|no|否|不是) printf '%s' "n" ;;
    *)
      log_warn "$(l10n "Please answer yes or no." "请输入是或否。")"
      prompt_yes_no "${label}" "${default_choice}"
      ;;
  esac
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "${value}"
}

url_encode() {
  local value="$1"
  local output=""
  local byte=""
  local char=""

  while IFS= read -r byte; do
    case "${byte}" in
      "")
        continue
        ;;
      2d|2e|5f|7e|3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a])
        printf -v char '%b' "\\x${byte}"
        output+="${char}"
        ;;
      *)
        output+="%${byte^^}"
        ;;
    esac
  done < <(printf '%s' "${value}" | LC_ALL=C od -An -tx1 -v | tr -s '[:space:]' '\n')

  printf '%s' "${output}"
}

detect_public_ip() {
  local ip=""

  ip=$(curl -4fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)
  if [[ -z "${ip}" ]]; then
    ip=$(curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)
  fi

  printf '%s' "${ip}"
}

build_ss_uri() {
  local host="$1"
  local uri_host="${host}"
  local userinfo
  local encoded_userinfo

  if [[ "${uri_host}" == *:* && "${uri_host}" != \[*\] ]]; then
    uri_host="[${uri_host}]"
  fi

  userinfo="${METHOD}:${PASSWORD}"
  encoded_userinfo=$(printf '%s' "${userinfo}" | base64 | tr -d '\n=' | tr '+/' '-_')
  printf 'ss://%s@%s:%s#%s' "${encoded_userinfo}" "${uri_host}" "${SERVER_PORT}" "$(url_encode "${CONFIG_NAME}")"
}

print_banner() {
  printf '\n=========================================\n'
  printf '%s\n' "$(l10n "Shadowsocks-rust server manager" "Shadowsocks-rust 服务端管理脚本")"
  printf '=========================================\n'
}

print_summary() {
  local public_ip=""
  local reveal_secret="n"
  local ss_uri=""

  if [[ "${SCRIPT_LANG}" == "zh" ]]; then
    cat <<EOF

安装完成。

版本：          ${INSTALL_VERSION}
发布文件：      ${ASSET_NAME}
程序路径：      ${BIN_DIR}/ssserver
配置路径：      ${CONFIG_PATH}
服务名称：      ${SERVICE_NAME}
监听地址：      ${LISTEN_ADDRESS}
服务端口：      ${SERVER_PORT}
加密方法：      ${METHOD}
密码/key：      ********
流量模式：      ${MODE}
超时时间：      ${TIMEOUT_SECONDS}
防火墙：        ${FIREWALL_MANAGER:-手动配置}

常用命令：
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
EOF
  else
    cat <<EOF

Installation completed.

Version:        ${INSTALL_VERSION}
Asset:          ${ASSET_NAME}
Binary path:    ${BIN_DIR}/ssserver
Config path:    ${CONFIG_PATH}
Service:        ${SERVICE_NAME}
Bind address:   ${LISTEN_ADDRESS}
Server port:    ${SERVER_PORT}
Method:         ${METHOD}
Password/key:   ********
Mode:           ${MODE}
Timeout:        ${TIMEOUT_SECONDS}
Firewall:       ${FIREWALL_MANAGER:-manual}

Useful commands:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
EOF
  fi

  reveal_secret=$(prompt_yes_no "$(l10n "Show the password/key and share link now?" "是否现在显示密码/key 和分享链接？")" "n")
  if [[ "${reveal_secret}" != "y" ]]; then
    printf '\n%s\n' "$(l10n "Use View configuration from the menu when you need the credentials." "需要凭据时，请使用菜单中的查看配置信息功能。")"
    return 0
  fi

  printf '\n%s %s\n' "$(l10n "Password/key:" "密码/key：")" "${PASSWORD}"
  public_ip=$(detect_public_ip)
  if [[ -n "${public_ip}" ]]; then
    ss_uri=$(build_ss_uri "${public_ip}")
  fi

  if [[ -n "${ss_uri}" ]]; then
    printf '\n%s\n  %s\n' "$(l10n "Share link:" "分享链接：")" "${ss_uri}"
  else
    printf '\n%s\n' "$(l10n "Public IP detection failed; build the ss:// link manually with your server IP." "公网 IP 检测失败，请使用服务器 IP 手动生成 ss:// 链接。")"
  fi
}

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap cleanup EXIT
  trap on_error ERR
  main "$@"
fi

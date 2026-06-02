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
DEFAULT_BIND_ADDRESS="::"
DEFAULT_PORT="8388"
DEFAULT_METHOD="2022-blake3-aes-128-gcm"
DEFAULT_MODE="tcp_and_udp"
DEFAULT_TIMEOUT="300"
TMP_DIR=""
COMMON_METHODS=(
  "2022-blake3-aes-128-gcm|Recommended default. AEAD 2022 with AES-128-GCM."
  "2022-blake3-aes-256-gcm|AEAD 2022 with AES-256-GCM."
  "2022-blake3-chacha20-poly1305|AEAD 2022 for hosts or clients that prefer ChaCha20."
  "chacha20-ietf-poly1305|Widely compatible classic AEAD cipher."
  "aes-128-gcm|Widely compatible classic AEAD cipher."
  "aes-256-gcm|Widely compatible classic AEAD cipher."
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

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

on_error() {
  local exit_code=$?
  log_error "Installation failed at line ${BASH_LINENO[0]} (exit ${exit_code})."
  exit "${exit_code}"
}

main() {
  require_root
  require_systemd
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

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "Run this installer as root, for example: sudo bash ${SCRIPT_NAME}"
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl is required. This installer only supports systemd-based Linux systems."
    exit 1
  fi

  if [[ ! -d /run/systemd/system ]]; then
    log_error "systemd does not appear to be the active init system on this host."
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
    head
    id
    install
    mkdir
    mktemp
    rm
    sed
    sha256sum
    tail
    tar
    tr
    uname
    useradd
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
    log_error "Could not install missing prerequisites automatically. Missing commands: $(join_words "${missing[@]}")"
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
    log_error "No package mapping for missing commands on ${manager}: $(join_words "${unmapped[@]}")"
    exit 1
  fi

  log_info "Missing commands: $(join_words "${missing[@]}")"
  log_info "Installing minimal prerequisite packages with ${manager}: $(join_words "${packages[@]}")"

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
      log_error "Unsupported package manager: ${manager}"
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
    log_error "Prerequisites are still missing after package installation: $(join_words "${missing[@]}")"
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
    base64|cat|chmod|chown|cp|date|head|id|install|mkdir|mktemp|rm|sha256sum|tail|tr|uname)
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
    groupadd|useradd)
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

  VERSION_INPUT=$(prompt_default "Version to install (blank = latest stable release)" "")
  LISTEN_ADDRESS=$(prompt_default "Bind address" "${DEFAULT_BIND_ADDRESS}")
  SERVER_PORT=$(prompt_default "Server port" "${DEFAULT_PORT}")
  METHOD=$(select_method)
  PASSWORD=$(prompt_default "Password/key (blank = auto-generate with ssservice genkey)" "")
  MODE=$(prompt_default "Traffic mode" "${DEFAULT_MODE}")
  TIMEOUT_SECONDS=$(prompt_default "Timeout in seconds" "${DEFAULT_TIMEOUT}")
  CONFIG_NAME=$(prompt_default "Node name for the summary link" "shadowsocks-rust")

  if [[ -n "${FIREWALL_MANAGER}" ]]; then
    OPEN_FIREWALL=$(prompt_yes_no "Detected ${FIREWALL_MANAGER}. Open TCP/UDP ${SERVER_PORT} automatically?" "y")
  else
    OPEN_FIREWALL="n"
  fi

  validate_port "${SERVER_PORT}"
  validate_timeout "${TIMEOUT_SECONDS}"
  validate_mode "${MODE}"
}

fetch_release_metadata() {
  local endpoint

  if [[ -z "${VERSION_INPUT}" || "${VERSION_INPUT}" == "latest" ]]; then
    endpoint="${REPO_API_BASE}/latest"
  else
    VERSION_INPUT=$(normalize_version "${VERSION_INPUT}")
    endpoint="${REPO_API_BASE}/tags/${VERSION_INPUT}"
  fi

  log_info "Fetching release metadata from GitHub."
  RELEASE_JSON=$(curl -fsSL "${endpoint}")
  INSTALL_VERSION=$(printf '%s\n' "${RELEASE_JSON}" | sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -n1)

  if [[ -z "${INSTALL_VERSION}" ]]; then
    log_error "Could not determine the release version from GitHub."
    exit 1
  fi
}

choose_release_asset() {
  local -a candidates=()
  local candidate

  mapfile -t candidates < <(asset_candidates "${INSTALL_VERSION}")

  for candidate in "${candidates[@]}"; do
    ASSET_URL=$(asset_url_from_release "${candidate}")
    if [[ -n "${ASSET_URL}" ]]; then
      ASSET_NAME="${candidate}"
      SHA256_URL="${ASSET_URL}.sha256"
      log_info "Selected release asset: ${ASSET_NAME}"
      return
    fi
  done

  log_error "No compatible Linux asset was found for architecture $(uname -m)."
  exit 1
}

download_and_verify_release() {
  local archive_path
  local checksum_path

  TMP_DIR=$(mktemp -d)
  archive_path="${TMP_DIR}/${ASSET_NAME}"
  checksum_path="${TMP_DIR}/${ASSET_NAME}.sha256"

  log_info "Downloading ${ASSET_NAME}"
  curl -fL --progress-bar -o "${archive_path}" "${ASSET_URL}"
  curl -fL --progress-bar -o "${checksum_path}" "${SHA256_URL}"

  log_info "Verifying archive checksum"
  (
    cd "${TMP_DIR}"
    sha256sum -c "${ASSET_NAME}.sha256"
  )

  log_info "Extracting archive"
  tar -xJf "${archive_path}" -C "${TMP_DIR}"
}

install_binaries() {
  local binary
  local binary_path

  for binary in ssserver ssservice; do
    binary_path=$(find "${TMP_DIR}" -type f -name "${binary}" -perm -u+x | head -n1)
    if [[ -z "${binary_path}" ]]; then
      log_error "Could not find ${binary} in the release archive."
      exit 1
    fi

    install -m 0755 "${binary_path}" "${BIN_DIR}/${binary}"
  done
}

ensure_supported_method() {
  while ! "${BIN_DIR}/ssservice" genkey -m "${METHOD}" >/dev/null 2>&1; do
    log_warn "The installed ssservice build does not accept method: ${METHOD}"
    METHOD=$(select_method)
  done
}

ensure_service_account() {
  local nologin_shell

  if ! getent group "${SERVICE_USER}" >/dev/null 2>&1; then
    groupadd --system "${SERVICE_USER}"
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
  fi
}

write_server_config() {
  local rendered_password
  local backup_suffix

  mkdir -p "${CONFIG_DIR}"
  chmod 0750 "${CONFIG_DIR}"

  if [[ -f "${CONFIG_PATH}" ]]; then
    backup_suffix=$(date +%Y%m%d-%H%M%S)
    cp -a "${CONFIG_PATH}" "${CONFIG_PATH}.${backup_suffix}.bak"
    log_warn "Existing config backed up to ${CONFIG_PATH}.${backup_suffix}.bak"
  fi

  if [[ -z "${PASSWORD}" ]]; then
    PASSWORD=$("${BIN_DIR}/ssservice" genkey -m "${METHOD}" | tail -n1 | tr -d '\r')
    if [[ -z "${PASSWORD}" ]]; then
      log_error "Failed to generate a password/key with ssservice genkey."
      exit 1
    fi
  fi

  rendered_password=$(json_escape "${PASSWORD}")

  cat >"${CONFIG_PATH}" <<EOF
{
  "server": "$(json_escape "${LISTEN_ADDRESS}")",
  "server_port": ${SERVER_PORT},
  "password": "${rendered_password}",
  "method": "$(json_escape "${METHOD}")",
  "mode": "$(json_escape "${MODE}")",
  "timeout": ${TIMEOUT_SECONDS}
}
EOF

  chmod 0640 "${CONFIG_PATH}"
  chown root:"${SERVICE_USER}" "${CONFIG_PATH}"
}

write_systemd_unit() {
  local backup_suffix

  if [[ -f "${SERVICE_PATH}" ]]; then
    backup_suffix=$(date +%Y%m%d-%H%M%S)
    cp -a "${SERVICE_PATH}" "${SERVICE_PATH}.${backup_suffix}.bak"
    log_warn "Existing service file backed up to ${SERVICE_PATH}.${backup_suffix}.bak"
  fi

  cat >"${SERVICE_PATH}" <<EOF
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
}

maybe_open_firewall() {
  if [[ "${OPEN_FIREWALL}" != "y" ]]; then
    return
  fi

  case "${FIREWALL_MANAGER}" in
    firewalld)
      firewall-cmd --permanent --add-port="${SERVER_PORT}/tcp"
      firewall-cmd --permanent --add-port="${SERVER_PORT}/udp"
      firewall-cmd --reload
      ;;
    ufw)
      ufw allow "${SERVER_PORT}/tcp"
      ufw allow "${SERVER_PORT}/udp"
      ;;
    *)
      log_warn "Firewall auto-open is not supported on this host. Open TCP/UDP ${SERVER_PORT} manually."
      ;;
  esac
}

enable_and_restart_service() {
  log_info "Reloading systemd and starting ${SERVICE_NAME}"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
  systemctl --no-pager --full status "${SERVICE_NAME}" | sed -n '1,12p'
}

detect_firewall_manager() {
  FIREWALL_MANAGER=""

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FIREWALL_MANAGER="firewalld"
    return
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^status: active'; then
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
      log_error "Unsupported architecture: $1"
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
    log_error "Port must be an integer between 1 and 65535."
    exit 1
  fi
}

validate_timeout() {
  local value="$1"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    log_error "Timeout must be a positive integer."
    exit 1
  fi
}

validate_mode() {
  case "$1" in
    tcp_only|udp_only|tcp_and_udp) ;;
    *)
      log_error "Mode must be one of: tcp_only, udp_only, tcp_and_udp."
      exit 1
      ;;
  esac
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

select_method() {
  local choice=""
  local manual_method=""
  local index=1
  local entry=""
  local method=""
  local description=""
  local manual_option=0

  while true; do
    printf '\nCommon cipher methods supported by shadowsocks-rust:\n' >&2
    index=1
    for entry in "${COMMON_METHODS[@]}"; do
      method=${entry%%|*}
      description=${entry#*|}
      printf '  %d) %s\n     %s\n' "${index}" "${method}" "${description}" >&2
      index=$((index + 1))
    done
    manual_option=${index}
    printf '  %d) Manual input\n' "${manual_option}" >&2

    read -r -p "Select cipher method [1]: " choice
    choice=${choice:-1}

    if [[ "${choice}" =~ ^[0-9]+$ ]]; then
      if (( choice >= 1 && choice < manual_option )); then
        printf '%s' "${COMMON_METHODS[choice-1]%%|*}"
        return 0
      fi

      if (( choice == manual_option )); then
        read -r -p "Enter cipher method exactly as supported by shadowsocks-rust: " manual_method
        manual_method=$(printf '%s' "${manual_method}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        if [[ -n "${manual_method}" ]]; then
          printf '%s' "${manual_method}"
          return 0
        fi
      fi
    fi

    log_warn "Invalid selection. Please choose one of the listed numbers."
  done
}

prompt_yes_no() {
  local label="$1"
  local default_choice="$2"
  local reply=""

  if [[ "${default_choice}" == "y" ]]; then
    read -r -p "${label} [Y/n]: " reply
    reply=${reply:-y}
  else
    read -r -p "${label} [y/N]: " reply
    reply=${reply:-n}
  fi

  reply=$(printf '%s' "${reply}" | tr '[:upper:]' '[:lower:]')
  case "${reply}" in
    y|yes) printf '%s' "y" ;;
    n|no) printf '%s' "n" ;;
    *)
      log_warn "Please answer yes or no."
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
  local index
  local char

  for (( index = 0; index < ${#value}; index += 1 )); do
    char="${value:index:1}"
    case "${char}" in
      [a-zA-Z0-9.~_-])
        output+="${char}"
        ;;
      *)
        printf -v char_hex '%%%02X' "'${char}"
        output+="${char_hex}"
        ;;
    esac
  done

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
  local userinfo
  local encoded_userinfo

  userinfo="${METHOD}:${PASSWORD}"
  encoded_userinfo=$(printf '%s' "${userinfo}" | base64 | tr -d '\n=' | tr '+/' '-_')
  printf 'ss://%s@%s:%s#%s' "${encoded_userinfo}" "${host}" "${SERVER_PORT}" "$(url_encode "${CONFIG_NAME}")"
}

print_banner() {
  cat <<'EOF'
=========================================
Shadowsocks-rust server installer
=========================================
This script installs ssserver + ssservice from the official GitHub releases,
creates /etc/shadowsocks-rust/config.json, and manages a systemd service.
EOF
}

print_summary() {
  local public_ip
  local ss_uri=""

  public_ip=$(detect_public_ip)
  if [[ -n "${public_ip}" ]]; then
    ss_uri=$(build_ss_uri "${public_ip}")
  fi

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
Password/key:   ${PASSWORD}
Mode:           ${MODE}
Timeout:        ${TIMEOUT_SECONDS}
Firewall:       ${FIREWALL_MANAGER:-manual}

Useful commands:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  cat ${CONFIG_PATH}
EOF

  if [[ -n "${ss_uri}" ]]; then
    printf '\nShare link template:\n  %s\n' "${ss_uri}"
  else
    printf '\nPublic IP detection failed; build the ss:// link manually with your server IP.\n'
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

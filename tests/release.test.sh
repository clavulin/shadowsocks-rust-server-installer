#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/install.sh"

fail() {
  printf 'release regression failed: %s\n' "$1" >&2
  exit 1
}

asset_candidates() {
  printf '%s\n' \
    'shadowsocks-v-test.preferred.tar.xz' \
    'shadowsocks-v-test.fallback.tar.xz'
}

asset_url_from_release() {
  case "$1" in
    shadowsocks-v-test.preferred.tar.xz)
      return 1
      ;;
    shadowsocks-v-test.fallback.tar.xz)
      printf '%s' 'https://example.invalid/shadowsocks-v-test.fallback.tar.xz'
      ;;
    *)
      return 1
      ;;
  esac
}

# shellcheck disable=SC2034 # Used by choose_release_asset and localization.
SCRIPT_LANG='en'
# shellcheck disable=SC2034 # Used by sourced choose_release_asset.
INSTALL_VERSION='v-test'
choose_release_asset >/dev/null

[[ "${ASSET_NAME}" == 'shadowsocks-v-test.fallback.tar.xz' ]] || \
  fail "expected fallback asset, got '${ASSET_NAME}'"
[[ "${ASSET_URL}" == 'https://example.invalid/shadowsocks-v-test.fallback.tar.xz' ]] || \
  fail "unexpected fallback URL '${ASSET_URL}'"
[[ "${SHA256_URL}" == "${ASSET_URL}.sha256" ]] || \
  fail "unexpected checksum URL '${SHA256_URL}'"

printf 'release regression passed\n'

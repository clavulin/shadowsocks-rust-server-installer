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

# An asset whose binaries cannot execute here must be skipped in favour of the
# next candidate instead of being installed and failing later.
asset_candidates() {
  printf '%s\n' \
    'shadowsocks-v-test.broken.tar.xz' \
    'shadowsocks-v-test.runnable.tar.xz'
}

asset_url_from_release() {
  printf 'https://example.invalid/%s' "$1"
}

download_and_verify_release() {
  local binary

  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
  TMP_DIR=$(mktemp -d)

  for binary in ssserver ssservice; do
    if [[ "${ASSET_NAME}" == *runnable* ]]; then
      printf '#!/bin/sh\nexit 0\n' >"${TMP_DIR}/${binary}"
    else
      printf '#!/bin/sh\necho "libc.so.6: version GLIBC_2.34 not found" >&2\nexit 1\n' \
        >"${TMP_DIR}/${binary}"
    fi
    chmod 0755 "${TMP_DIR}/${binary}"
  done
}

TMP_DIR=""
prepare_release >/dev/null 2>&1

[[ "${ASSET_NAME}" == 'shadowsocks-v-test.runnable.tar.xz' ]] || \
  fail "expected the runnable asset, got '${ASSET_NAME}'"

rm -rf -- "${TMP_DIR}"

printf 'release regression passed\n'

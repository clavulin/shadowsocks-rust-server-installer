#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

pick_utf8_locale() {
  local candidates=("C.UTF-8" "en_US.UTF-8" "en_US.utf8" "UTF-8")
  local candidate

  for candidate in "${candidates[@]}"; do
    if locale -a 2>/dev/null | grep -Fxqi "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  printf 'No UTF-8 locale available for regression test.\n' >&2
  exit 1
}

UTF8_LOCALE="$(pick_utf8_locale)"
export LC_ALL="${UTF8_LOCALE}"

# shellcheck source=/dev/null
source "${REPO_ROOT}/install.sh"

expected='%F0%9F%87%BA%F0%9F%87%B8%20GatewaySentry%20LAX.2C4G'
actual="$(url_encode '🇺🇸 GatewaySentry LAX.2C4G')"
multi_flag_expected='%F0%9F%87%BA%F0%9F%87%B8%F0%9F%87%AF%F0%9F%87%B5%F0%9F%87%AD%F0%9F%87%B0%F0%9F%87%B8%F0%9F%87%AC%F0%9F%87%B2%F0%9F%87%BE%F0%9F%87%A9%F0%9F%87%AA%F0%9F%87%AC%F0%9F%87%A7%F0%9F%87%B3%F0%9F%87%B1%F0%9F%87%A6%F0%9F%87%BA'
multi_flag_actual="$(url_encode '🇺🇸🇯🇵🇭🇰🇸🇬🇲🇾🇩🇪🇬🇧🇳🇱🇦🇺')"
plain_expected='GatewaySentry-LAX.2C4G_~'
plain_actual="$(url_encode 'GatewaySentry-LAX.2C4G_~')"

if [[ "${actual}" != "${expected}" ]]; then
  printf 'url_encode regression failed\nexpected: %s\nactual:   %s\n' "${expected}" "${actual}" >&2
  exit 1
fi

if [[ "${plain_actual}" != "${plain_expected}" ]]; then
  printf 'url_encode ASCII sanity check failed\nexpected: %s\nactual:   %s\n' "${plain_expected}" "${plain_actual}" >&2
  exit 1
fi

if [[ "${multi_flag_actual}" != "${multi_flag_expected}" ]]; then
  printf 'url_encode multi-flag regression failed\nexpected: %s\nactual:   %s\n' "${multi_flag_expected}" "${multi_flag_actual}" >&2
  exit 1
fi

printf 'url_encode regression passed\n'

#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/install.sh"

fail() {
  printf 'menu regression failed: %s\n' "$1" >&2
  exit 1
}

assert_calls() {
  local expected="$1"
  local context="$2"
  local actual=""

  if (( ${#CALLS[@]} > 0 )); then
    actual=$(printf '%s\n' "${CALLS[@]}")
  fi
  [[ "${actual}" == "${expected}" ]] || \
    fail "${context}: expected '${expected}', got '${actual}'"
}

CALLS=()

# Every service operation is stopped at run_action; no service action or
# systemctl implementation is allowed to execute in this regression test.
run_action() {
  CALLS+=("$1:$2")
}

start_service_action() {
  fail 'start service action should be stubbed by run_action'
}

stop_service_action() {
  fail 'stop service action should be stubbed by run_action'
}

restart_service_action() {
  fail 'restart service action should be stubbed by run_action'
}

# shellcheck disable=SC2218 # The later redefinition is intentional for top-level dispatch.
service_menu <<< '1' >/dev/null 2>&1
assert_calls 'start:start_service_action' 'service menu start dispatch'

CALLS=()
# shellcheck disable=SC2218
service_menu <<< '2' >/dev/null 2>&1
assert_calls 'stop:stop_service_action' 'service menu stop dispatch'

CALLS=()
# shellcheck disable=SC2218
service_menu <<< '3' >/dev/null 2>&1
assert_calls 'restart:restart_service_action' 'service menu restart dispatch'

CALLS=()
# shellcheck disable=SC2218
service_menu <<< '0' >/dev/null 2>&1
assert_calls '' 'service menu back dispatch'

# The main menu uses the same run_action recorder. The service and language
# submenus are also replaced so the test covers only top-level dispatch.
service_menu() {
  CALLS+=('service-menu')
}

choose_language() {
  CALLS+=("language:$1")
}

print_banner() {
  :
}

installation_status_label() {
  printf '%s' 'test-status'
}

install_action() {
  fail 'install action should be stubbed by run_action'
}

update_action() {
  fail 'update action should be stubbed by run_action'
}

uninstall_action() {
  fail 'uninstall action should be stubbed by run_action'
}

modify_config_action() {
  fail 'modify action should be stubbed by run_action'
}

view_config_action() {
  fail 'view action should be stubbed by run_action'
}

view_status_action() {
  fail 'status action should be stubbed by run_action'
}

# shellcheck disable=SC2034 # Used by sourced main_menu through l10n/choose_language.
SCRIPT_LANG='zh'
CALLS=()
main_menu <<< $'1\n2\n3\n4\n5\n6\n7\n8\n0\n' >/dev/null 2>&1
assert_calls $'install:install_action\nupdate:update_action\nuninstall:uninstall_action\nservice-menu\nmodify:modify_config_action\nview:view_config_action\nstatus:view_status_action\nlanguage:zh' \
  'main menu dispatch'

printf 'menu regression passed\n'

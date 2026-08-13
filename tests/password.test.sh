#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/install.sh"

fail() {
  printf 'password regression failed: %s\n' "$1" >&2
  exit 1
}

assert_valid() {
  local method="$1"
  local password="$2"

  validate_password_for_method "${method}" "${password}" 2>/dev/null || \
    fail "expected valid password for ${method}"
}

assert_invalid() {
  local method="$1"
  local password="$2"

  if validate_password_for_method "${method}" "${password}" 2>/dev/null; then
    fail "expected invalid password for ${method}"
  fi
}

key_16_padded='MDEyMzQ1Njc4OWFiY2RlZg=='
key_16_unpadded='MDEyMzQ1Njc4OWFiY2RlZg'
key_32_padded='MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY='
key_32_unpadded='MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY'

assert_valid '2022-blake3-aes-128-gcm' "${key_16_padded}"
assert_valid '2022-blake3-aes-128-gcm' "${key_16_unpadded}"
assert_valid '2022-blake3-aes-128-gcm' "${key_16_unpadded}="
assert_invalid '2022-blake3-aes-128-gcm' 'my-password'
assert_invalid '2022-blake3-aes-128-gcm' "${key_16_unpadded}==="
assert_invalid '2022-blake3-aes-128-gcm' 'MDEyMzQ1Njc4OWFiY2RlZh=='
assert_invalid '2022-blake3-aes-128-gcm' "${key_32_padded}"
assert_invalid '2022-blake3-aes-128-gcm' '_____________________w=='

assert_valid '2022-blake3-aes-256-gcm' "${key_32_padded}"
assert_valid '2022-blake3-chacha20-poly1305' "${key_32_unpadded}"
assert_invalid '2022-blake3-aes-256-gcm' "${key_32_unpadded}=="
assert_invalid '2022-blake3-aes-256-gcm' "${key_16_padded}"
assert_invalid '2022-future-method' "${key_32_padded}"

# shellcheck disable=SC2329 # Invoked indirectly by validate_password_for_method.
base64() {
  busybox base64 "$@"
}

if command -v busybox >/dev/null 2>&1; then
  assert_valid '2022-blake3-aes-128-gcm' "${key_16_unpadded}"
  assert_valid '2022-blake3-aes-256-gcm' "${key_32_unpadded}"
fi

unset -f base64

assert_valid 'aes-256-gcm' 'correct horse battery staple'
assert_valid 'chacha20-ietf-poly1305' '密码 with spaces: "quotes" and \\slashes'
assert_invalid 'aes-256-gcm' $'password\x01value'

prompt_result=$(prompt_password '2022-blake3-aes-128-gcm' \
  <<< $'not-a-key\nMDEyMzQ1Njc4OWFiY2RlZg==\n' 2>/dev/null)
[[ "${prompt_result}" == "${key_16_padded}" ]] || fail 'prompt did not retry until the key was valid'

prompt_result=$(prompt_password 'aes-256-gcm' <<< $'\n' 2>/dev/null)
[[ -z "${prompt_result}" ]] || fail 'blank input did not select random generation'

if prompt_password 'aes-256-gcm' </dev/null >/dev/null 2>&1; then
  fail 'end-of-input should stop the password prompt'
fi

mock_bin_dir=$(mktemp -d)
trap 'rm -rf "${mock_bin_dir}"' EXIT
cat >"${mock_bin_dir}/ssservice" <<'EOF'
#!/usr/bin/env bash

if [[ "$*" == *"unsupported-method"* ]]; then
  exit 1
fi
EOF
chmod +x "${mock_bin_dir}/ssservice"

select_method() {
  printf '%s' '2022-blake3-aes-128-gcm'
}

# shellcheck disable=SC2034 # Used by ensure_supported_method from sourced install.sh.
BIN_DIR="${mock_bin_dir}"
METHOD='unsupported-method'
PASSWORD='legacy-password'
ensure_supported_method <<< "${key_16_padded}" 2>/dev/null
[[ "${METHOD}" == '2022-blake3-aes-128-gcm' ]] || fail 'unsupported method was not replaced'
[[ "${PASSWORD}" == "${key_16_padded}" ]] || fail 'password was not revalidated after method replacement'

printf 'password regression passed\n'

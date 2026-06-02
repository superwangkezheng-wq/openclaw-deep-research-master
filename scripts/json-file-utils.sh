#!/bin/zsh

safe_jq_update_file() {
  if (( $# < 1 )); then
    echo "Usage: safe_jq_update_file <target_file> <jq_args...>" >&2
    return 1
  fi

  local target_file="$1"
  shift

  if [[ -z "${target_file}" ]]; then
    echo "safe_jq_update_file target_file must not be empty" >&2
    return 1
  fi

  local tmp_file=""
  {
    tmp_file="$(mktemp)"
    if ! jq "$@" "${target_file}" > "${tmp_file}"; then
      echo "Failed to update JSON file: ${target_file}" >&2
      return 1
    fi

    if [[ ! -s "${tmp_file}" ]]; then
      echo "Refusing to replace JSON file with empty output: ${target_file}" >&2
      return 1
    fi

    mv "${tmp_file}" "${target_file}"
    tmp_file=""
  } always {
    [[ -n "${tmp_file}" && -e "${tmp_file}" ]] && rm -f "${tmp_file}"
  }
}

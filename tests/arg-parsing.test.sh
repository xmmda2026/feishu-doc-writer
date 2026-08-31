#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_capture() {
  local name="$1"
  shift
  local out err status
  out="$(mktemp)"
  err="$(mktemp)"
  if "$@" >"${out}" 2>"${err}"; then
    status=0
  else
    status=$?
  fi
  RUN_STATUS="${status}"
  RUN_OUTPUT="$(cat "${out}")"
  RUN_ERROR="$(cat "${err}")"
  rm -f "${out}" "${err}"
  echo "ok: ${name}"
}

assert_status() {
  local expected="$1"
  [ "${RUN_STATUS}" -eq "${expected}" ] || fail "expected status ${expected}, got ${RUN_STATUS}; stderr=${RUN_ERROR}"
}

assert_stderr_contains() {
  local pattern="$1"
  grep -Fq -- "${pattern}" <<<"${RUN_ERROR}" || fail "stderr did not contain ${pattern}; stderr=${RUN_ERROR}"
}

run_capture "custom help" bash "${ROOT_DIR}/scripts/write-custom-doc.sh" --help
assert_status 0
assert_stderr_contains "usage: "
assert_stderr_contains "--title TITLE --content CONTENT_MD_FILE [--image-dir IMAGE_DIR]"

run_capture "custom rejects positional arguments" bash "${ROOT_DIR}/scripts/write-custom-doc.sh" "Title" "/tmp/content.md"
assert_status 2
assert_stderr_contains "unknown argument: Title"

run_capture "valid help" bash "${ROOT_DIR}/scripts/write-valid-doc.sh" --help
assert_status 0
assert_stderr_contains "usage: "
assert_stderr_contains "--input RESULT_FILE"

run_capture "valid rejects positional arguments" bash "${ROOT_DIR}/scripts/write-valid-doc.sh" "/tmp/result.json"
assert_status 2
assert_stderr_contains "unknown argument: /tmp/result.json"

run_capture "valid requires input" bash "${ROOT_DIR}/scripts/write-valid-doc.sh" --resume-phase2
assert_status 2
assert_stderr_contains "usage: ./scripts/write-valid-doc.sh --input RESULT_FILE"

run_capture "chapter uses custom flags" grep -F -- '--title' "${ROOT_DIR}/scripts/chapter-to-feishu.sh"
assert_status 0

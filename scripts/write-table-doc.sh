#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="${SKILL_DIR}/tmp"
mkdir -p "${TMP_DIR}"

log() {
  echo "[write-table-doc] $*" >&2
}

usage() {
  echo "usage: $0 --input INPUT_FILE [--title TITLE]" >&2
}

fail_usage() {
  echo "ERROR: $*" >&2
  usage
  exit 2
}

INPUT_FILE=""
TITLE_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      [ "$#" -ge 2 ] || fail_usage "--input requires a value"
      INPUT_FILE="$2"
      shift 2
      ;;
    --title)
      [ "$#" -ge 2 ] || fail_usage "--title requires a value"
      TITLE_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail_usage "unknown argument: $1"
      ;;
  esac
done

[ -n "${INPUT_FILE}" ] || fail_usage "--input is required"
[ -f "${INPUT_FILE}" ] || { echo "ERROR: input file not found: ${INPUT_FILE}" >&2; exit 2; }
jq -e . "${INPUT_FILE}" >/dev/null || { echo "ERROR: input file is not valid JSON: ${INPUT_FILE}" >&2; exit 2; }

VALIDATION_FILTER='
  def die($msg): error($msg);
  (.headers | length) as $columns |
  if (.headers | type) != "array" then die("headers must be an array")
  elif $columns < 1 or $columns > 9 then die("headers must contain 1 to 9 columns")
  elif any(.headers[]; type == "array" or type == "object" or tostring == "") then die("headers must be a non-empty scalar array")
  elif (.rows | type) != "array" then die("rows must be a two-dimensional array")
  elif any(.rows[]; type != "array") then die("rows must be a two-dimensional array")
  elif any(.rows[]; length != $columns) then die("each row must have the same column count as headers")
  elif has("col_widths") and (.col_widths | type) != "array" then die("col_widths must be an array when provided")
  elif has("col_widths") and ((.col_widths | length) != $columns) then die("col_widths length must match headers")
  else true end
'
jq -e "${VALIDATION_FILTER}" "${INPUT_FILE}" >/dev/null \
  || { echo "ERROR: input validation failed" >&2; exit 2; }

RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
WORK_DIR="${TMP_DIR}/write-table-doc-${RUN_ID}"
mkdir -p "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

jq -c '.headers | map(tostring)' "${INPUT_FILE}" > "${WORK_DIR}/headers.json"
jq -c '.rows | map(map(tostring))' "${INPUT_FILE}" > "${WORK_DIR}/rows.json"
if jq -e 'has("col_widths")' "${INPUT_FILE}" >/dev/null; then
  jq -c '.col_widths' "${INPUT_FILE}" > "${WORK_DIR}/col_widths.json"
else
  jq -c '(.headers | length) as $cols | [range(0; $cols) | 200]' "${INPUT_FILE}" > "${WORK_DIR}/col_widths.json"
fi

COLUMNS="$(jq 'length' "${WORK_DIR}/headers.json")"
WRITTEN_ROWS="$(jq 'length' "${WORK_DIR}/rows.json")"
TITLE="$(jq -r '.title // "数据分析报告"' "${INPUT_FILE}")"
[ -n "${TITLE_OVERRIDE}" ] && TITLE="${TITLE_OVERRIDE}"
SUBTITLE="$(jq -r '.subtitle // empty' "${INPUT_FILE}")"

[ -f "${SKILL_DIR}/.env" ] && { set -a; source "${SKILL_DIR}/.env"; set +a; }
source "${SCRIPT_DIR}/feishu-api.sh"
: "${FEISHU_DOC_DOMAIN:?Set FEISHU_DOC_DOMAIN to your tenant document domain}"

write_one_table() {
  local token="$1" doc_token="$2" parent_block_id="$3" offset="$4" count="$5"
  local table_rows=$((count + 1))
  local expected_cells=$((table_rows * COLUMNS))
  local table_id cells_file actual_cells

  table_id="$(feishu_create_table "${token}" "${doc_token}" "${parent_block_id}" "${table_rows}" "${COLUMNS}" "$(cat "${WORK_DIR}/col_widths.json")")" \
    || return 1

  cells_file="${WORK_DIR}/cells-${offset}.json"
  feishu_list_block_children "${token}" "${doc_token}" "${table_id}" > "${cells_file}" || return 1
  actual_cells="$(jq 'length' "${cells_file}")"
  if [ "${actual_cells}" -ne "${expected_cells}" ]; then
    log "ERROR: table cell count mismatch: table=${table_id} expected=${expected_cells} actual=${actual_cells}"
    return 1
  fi

  local c r cell_index cell_id text
  for ((c = 0; c < COLUMNS; c++)); do
    cell_id="$(jq -r --argjson i "${c}" '.[$i]' "${cells_file}")"
    text="$(jq -r --argjson i "${c}" '.[$i]' "${WORK_DIR}/headers.json")"
    feishu_write_table_cell "${token}" "${doc_token}" "${cell_id}" "${text}" "true" \
      || { log "ERROR: write header cell failed: table=${table_id} column=${c}"; return 1; }
  done

  for ((r = 0; r < count; r++)); do
    for ((c = 0; c < COLUMNS; c++)); do
      cell_index=$(((r + 1) * COLUMNS + c))
      cell_id="$(jq -r --argjson i "${cell_index}" '.[$i]' "${cells_file}")"
      text="$(jq -r --argjson r "$((offset + r))" --argjson c "${c}" '.[$r][$c]' "${WORK_DIR}/rows.json")"
      feishu_write_table_cell "${token}" "${doc_token}" "${cell_id}" "${text}" "false" \
        || { log "ERROR: write data cell failed: table=${table_id} row=$((offset + r)) column=${c}"; return 1; }
    done
  done
}

log "validated input: rows=${WRITTEN_ROWS} columns=${COLUMNS}"
TOKEN="$(feishu_get_token)" || { log "ERROR: failed to get Feishu token"; exit 1; }
DOC_TOKEN="$(feishu_create_document "${TOKEN}" "${TITLE}")" || { log "ERROR: failed to create Feishu document"; exit 1; }
feishu_ensure_public_access "${TOKEN}" "${DOC_TOKEN}" || { log "ERROR: failed to ensure public access"; exit 1; }
ROOT_BLOCK="$(feishu_get_root_block "${TOKEN}" "${DOC_TOKEN}")" || { log "ERROR: failed to get root block"; exit 1; }

if [ -n "${SUBTITLE}" ]; then
  append_content "${TOKEN}" "${DOC_TOKEN}" "${SUBTITLE}" || { log "ERROR: failed to write subtitle"; exit 1; }
fi

offset=0
while [ "${offset}" -lt "${WRITTEN_ROWS}" ]; do
  chunk_size=$((WRITTEN_ROWS - offset))
  [ "${chunk_size}" -gt 8 ] && chunk_size=8
  log "writing table chunk: offset=${offset} rows=${chunk_size}"
  write_one_table "${TOKEN}" "${DOC_TOKEN}" "${ROOT_BLOCK}" "${offset}" "${chunk_size}" || exit 1
  offset=$((offset + chunk_size))
done

if [ "${WRITTEN_ROWS}" -eq 0 ]; then
  log "writing header-only table"
  write_one_table "${TOKEN}" "${DOC_TOKEN}" "${ROOT_BLOCK}" 0 0 || exit 1
fi

DOC_URL="https://${FEISHU_DOC_DOMAIN}/docx/${DOC_TOKEN}"
jq -nc \
  --arg status "success" \
  --arg doc_token "${DOC_TOKEN}" \
  --arg doc_url "${DOC_URL}" \
  --argjson written_rows "${WRITTEN_ROWS}" \
  --argjson columns "${COLUMNS}" \
  '{status:$status, doc_token:$doc_token, doc_url:$doc_url, written_rows:$written_rows, columns:$columns}'

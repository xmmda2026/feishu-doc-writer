#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKPOINT_FILE=""
INPUT_FILE=""
RENDER_ONLY=0

usage() { echo "usage: $0 --input INPUT_FILE [--checkpoint FILE] [--render-only]" >&2; }
fail_usage() { echo "ERROR: $*" >&2; usage; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) [ "$#" -ge 2 ] || fail_usage "--input requires a value"; INPUT_FILE="$2"; shift 2 ;;
    --checkpoint) [ "$#" -ge 2 ] || fail_usage "--checkpoint requires a value"; CHECKPOINT_FILE="$2"; shift 2 ;;
    --render-only) RENDER_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail_usage "unknown argument: $1" ;;
  esac
done

[ -n "$INPUT_FILE" ] || fail_usage "--input is required"
[ -f "$INPUT_FILE" ] || fail_usage "input file not found: $INPUT_FILE"
jq -e 'type == "object" and (.title | type == "string" and length > 0) and (.groups | type == "array")' "$INPUT_FILE" >/dev/null || fail_usage "input file is invalid"
[ -n "$CHECKPOINT_FILE" ] || CHECKPOINT_FILE="$(dirname "$INPUT_FILE")/daily-ledger-checkpoint.json"

render_lines() {
  jq -r '
    "# \(.title)",
    "",
    "运行时间：\(.date) \(.hour):00（上海时间）",
    "采集到候选：\(.summary.collectedCount) 个",
    "去重后候选：\(.summary.dedupedCount) 个",
    "最终通过：\(.summary.passedCount) 个",
    "本台账收录：\(.summary.includedCount) 个",
    "",
    "## 待处理筛选结果",
    "",
    (.groups[] | "## \(.title)（\(.count)）", "", (if .count == 0 then "- 本组无词" else .items[] | ("- " + .keyword + "｜KD：" + (if .kd == null then "暂无数据" else (.kd | tostring) end) + "｜" + .reason) end), ""),
    "## 关联资料",
    "",
    (if (.summary.validDocumentUrl // "") == "" then "- 验证详情文档：本轮未生成" else "- [验证详情文档](\(.summary.validDocumentUrl))" end)
  ' "$INPUT_FILE"
}

if [ "$RENDER_ONLY" -eq 1 ]; then
  render_lines
  exit 0
fi

mapfile -t LINES < <(render_lines)
CHUNKS_JSON="$(printf '%s\n' "${LINES[@]}" | jq -R -s 'split("\n") | if .[-1] == "" then .[:-1] else . end | [range(0; length; 40) as $i | .[$i:$i + 40]]')"
TOTAL_CHUNKS="$(jq 'length' <<<"$CHUNKS_JSON")"

if [ -f "$CHECKPOINT_FILE" ]; then
  jq -e --arg title "$(jq -r '.title' "$INPUT_FILE")" '.title == $title and (.chunks | type == "array") and (.nextChunk | type == "number")' "$CHECKPOINT_FILE" >/dev/null || { echo "ERROR: invalid checkpoint: $CHECKPOINT_FILE" >&2; exit 2; }
else
  mkdir -p "$(dirname "$CHECKPOINT_FILE")"
  jq -n --arg title "$(jq -r '.title' "$INPUT_FILE")" --argjson chunks "$CHUNKS_JSON" '{title:$title,chunks:$chunks,nextChunk:0,status:"writing",doc_token:"",doc_url:""}' > "$CHECKPOINT_FILE"
fi

if [ "$(jq -r '.status' "$CHECKPOINT_FILE")" = "done" ]; then
  jq -c --arg checkpoint "$CHECKPOINT_FILE" '{status:"success",doc_token,doc_url,written_chunks:(.chunks|length),checkpoint_file:$checkpoint}' "$CHECKPOINT_FILE"
  exit 0
fi

set -a
source /root/.openclaw/credentials/feishu.env
set +a
source "${SCRIPT_DIR}/feishu-api.sh"
token="$(get_feishu_token)" || { echo "ERROR: failed to get Feishu token" >&2; exit 1; }

doc_token="$(jq -r '.doc_token' "$CHECKPOINT_FILE")"
if [ -z "$doc_token" ]; then
  doc_token="$(create_document "$token" "$(jq -r '.title' "$INPUT_FILE")")" || { echo "ERROR: failed to create document" >&2; exit 1; }
  doc_url="https://${FEISHU_DOC_DOMAIN}/docx/${doc_token}"
  jq --arg token "$doc_token" --arg url "$doc_url" '.doc_token=$token | .doc_url=$url' "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.next"
  mv "${CHECKPOINT_FILE}.next" "$CHECKPOINT_FILE"
fi
ensure_document_public_access "$token" "$doc_token" || { echo "ERROR: failed to set document access" >&2; exit 1; }

while [ "$(jq -r '.nextChunk' "$CHECKPOINT_FILE")" -lt "$(jq '.chunks | length' "$CHECKPOINT_FILE")" ]; do
  index="$(jq -r '.nextChunk' "$CHECKPOINT_FILE")"
  content="$(jq -r --argjson index "$index" '.chunks[$index] | join("\n")' "$CHECKPOINT_FILE")"
  append_content "$token" "$doc_token" "$content" || { echo "ERROR: failed writing chunk ${index}" >&2; exit 1; }
  jq '.nextChunk += 1' "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.next"
  mv "${CHECKPOINT_FILE}.next" "$CHECKPOINT_FILE"
done

jq '.status="done"' "$CHECKPOINT_FILE" > "${CHECKPOINT_FILE}.next"
mv "${CHECKPOINT_FILE}.next" "$CHECKPOINT_FILE"
jq -c --arg checkpoint "$CHECKPOINT_FILE" '{status:"success",doc_token,doc_url,written_chunks:(.chunks|length),checkpoint_file:$checkpoint}' "$CHECKPOINT_FILE"

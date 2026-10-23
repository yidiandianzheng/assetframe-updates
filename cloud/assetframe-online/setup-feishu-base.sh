#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "用法：$0 <飞书多维表格 base_token> [表名]" >&2
    exit 1
fi
if ! command -v lark-cli >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "需要先安装并登录 lark-cli，同时确保 jq 可用。" >&2
    exit 1
fi

BASE_TOKEN="$1"
TABLE_NAME="${2:-产品反馈}"
FIELDS_JSON='[
  {"name":"反馈编号","type":"text"},
  {"name":"提交时间","type":"datetime","style":{"format":"yyyy-MM-dd HH:mm"}},
  {"name":"反馈类型","type":"select","multiple":false,"options":[{"name":"故障"},{"name":"体验优化"},{"name":"功能建议"},{"name":"其他"}]},
  {"name":"反馈内容","type":"text"},
  {"name":"状态","type":"select","multiple":false,"options":[{"name":"新反馈"},{"name":"处理中"},{"name":"待发布验证"},{"name":"已关闭"}]},
  {"name":"优先级","type":"select","multiple":false,"options":[{"name":"待评估"},{"name":"P0"},{"name":"P1"},{"name":"P2"},{"name":"P3"}]},
  {"name":"目标版本","type":"text"},
  {"name":"处理结论","type":"text"},
  {"name":"应用版本","type":"text"},
  {"name":"macOS版本","type":"text"},
  {"name":"芯片","type":"text"},
  {"name":"所在界面","type":"text"},
  {"name":"截图","type":"attachment"},
  {"name":"联系方式","type":"text"},
  {"name":"匿名安装标识","type":"text"}
]'

CREATE_RESULT="$(lark-cli base +table-create \
    --base-token "$BASE_TOKEN" \
    --name "$TABLE_NAME" \
    --fields "$FIELDS_JSON" \
    --format json)"
TABLE_ID="$(print -r -- "$CREATE_RESULT" | jq -r '.. | objects | .table_id? // empty' | head -1)"
if [[ -z "$TABLE_ID" || "$TABLE_ID" != tbl* ]]; then
    echo "表已请求创建，但无法从返回值识别 table_id：" >&2
    print -r -- "$CREATE_RESULT" >&2
    exit 1
fi

lark-cli base +view-create \
    --base-token "$BASE_TOKEN" \
    --table-id "$TABLE_ID" \
    --json '[{"name":"新反馈","type":"grid"},{"name":"按版本汇总","type":"grid"},{"name":"处理中","type":"grid"},{"name":"待发布验证","type":"grid"},{"name":"已关闭","type":"grid"}]' \
    --format json >/dev/null

lark-cli base +view-set-filter --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --view-id "新反馈" --json '{"logic":"and","conditions":[["状态","==","新反馈"]]}' --format json >/dev/null
lark-cli base +view-set-group --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --view-id "按版本汇总" --json '{"group_config":[{"field":"应用版本","desc":true}]}' --format json >/dev/null
lark-cli base +view-set-filter --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --view-id "处理中" --json '{"logic":"and","conditions":[["状态","==","处理中"]]}' --format json >/dev/null
lark-cli base +view-set-filter --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --view-id "待发布验证" --json '{"logic":"and","conditions":[["状态","==","待发布验证"]]}' --format json >/dev/null
lark-cli base +view-set-filter --base-token "$BASE_TOKEN" --table-id "$TABLE_ID" --view-id "已关闭" --json '{"logic":"and","conditions":[["状态","==","已关闭"]]}' --format json >/dev/null

echo "飞书反馈表已创建"
echo "FEISHU_APP_TOKEN=$BASE_TOKEN"
echo "FEISHU_TABLE_ID=$TABLE_ID"

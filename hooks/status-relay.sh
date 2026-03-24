#!/bin/bash
# TokenBox Status Relay — receives Claude Code Status events on stdin
# Extracts token counts, model, session ID, cost and writes to live.json
# Must complete in <10ms — no network calls, no heavy processing

set -euo pipefail

INPUT=$(cat)
DEST="$HOME/Library/Application Support/TokenBox"
mkdir -p "$DEST"

# Extract fields with jq (single pass for performance)
eval "$(echo "$INPUT" | jq -r '
  @sh "SESSION=\(.session_id // "")",
  @sh "MODEL=\(.model.id // .model.api_model_id // "unknown")",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "INPUT_T=\(.context_window.current_usage.input_tokens // 0)",
  @sh "OUTPUT_T=\(.context_window.current_usage.output_tokens // 0)",
  @sh "CACHE_W=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
  @sh "CACHE_R=\(.context_window.current_usage.cache_read_input_tokens // 0)"
' | tr ',' '\n')"

# Use local timezone (matches Swift app's Calendar.current.startOfDay)
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%z")

# Build JSON payload (compact — single line for JSONL compatibility)
PAYLOAD=$(jq -cn \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION" \
  --arg model "$MODEL" \
  --argjson cost "$COST" \
  --argjson in_t "$INPUT_T" \
  --argjson out "$OUTPUT_T" \
  --argjson cw "$CACHE_W" \
  --argjson cr "$CACHE_R" \
  '{ts:$ts,sid:$sid,model:$model,cost:$cost,in:$in_t,out:$out,cw:$cw,cr:$cr}')

# Atomic write to live.json (temp file + rename)
TMPFILE=$(mktemp "$DEST/live.XXXXXX.json")
echo "$PAYLOAD" > "$TMPFILE"
mv "$TMPFILE" "$DEST/live.json"

# Append to event log for batch import
echo "$PAYLOAD" >> "$DEST/events.jsonl"

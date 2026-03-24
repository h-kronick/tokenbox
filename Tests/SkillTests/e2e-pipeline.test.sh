#!/bin/bash
# End-to-end integration test: hook → live.json → app pipeline
# Tests that status-relay.sh correctly processes Claude Code Status events
# and writes valid JSON to live.json and events.jsonl

set -euo pipefail

HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/status-relay.sh"
PASS=0
FAIL=0
TOTAL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  ✓ %s${RESET}\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  ✗ %s — expected '%s', got '%s'${RESET}\n" "$label" "$expected" "$actual"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  ✓ %s${RESET}\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  ✗ %s — file not found: %s${RESET}\n" "$label" "$path"
  fi
}

# Override HOME to isolate test output from real data
export HOME
HOME=$(mktemp -d)
DEST="$HOME/Library/Application Support/TokenBox"
trap 'rm -rf "$HOME"' EXIT

printf "${BOLD}=== TokenBox E2E Pipeline Test ===${RESET}\n\n"

# ------------------------------------------------------------------
# Test 1: Basic event processing
# ------------------------------------------------------------------
printf "${BOLD}Test 1: Basic Status event → live.json + events.jsonl${RESET}\n"

EVENT1='{
  "session_id": "test-session-123",
  "model": { "id": "claude-sonnet-4-6", "display_name": "Sonnet" },
  "cost": { "total_cost_usd": 0.15 },
  "context_window": {
    "current_usage": {
      "input_tokens": 5000,
      "output_tokens": 800,
      "cache_creation_input_tokens": 3000,
      "cache_read_input_tokens": 1500
    }
  }
}'

echo "$EVENT1" | bash "$HOOK"

assert_file_exists "live.json created" "$DEST/live.json"
assert_file_exists "events.jsonl created" "$DEST/events.jsonl"

# Validate live.json is valid JSON and has correct fields
LIVE=$(cat "$DEST/live.json")
assert_eq "sid field" "test-session-123" "$(echo "$LIVE" | jq -r '.sid')"
assert_eq "model field" "claude-sonnet-4-6" "$(echo "$LIVE" | jq -r '.model')"
assert_eq "cost field" "0.15" "$(echo "$LIVE" | jq -r '.cost')"
assert_eq "in field" "5000" "$(echo "$LIVE" | jq -r '.in')"
assert_eq "out field" "800" "$(echo "$LIVE" | jq -r '.out')"
assert_eq "cw field" "3000" "$(echo "$LIVE" | jq -r '.cw')"
assert_eq "cr field" "1500" "$(echo "$LIVE" | jq -r '.cr')"
assert_eq "ts field present" "true" "$(echo "$LIVE" | jq 'has("ts")')"

JSONL_LINES=$(wc -l < "$DEST/events.jsonl" | tr -d ' ')
assert_eq "events.jsonl has 1 line" "1" "$JSONL_LINES"

echo ""

# ------------------------------------------------------------------
# Test 2: Second event — append behavior
# ------------------------------------------------------------------
printf "${BOLD}Test 2: Second event appends to events.jsonl${RESET}\n"

EVENT2='{
  "session_id": "test-session-456",
  "model": { "id": "claude-opus-4-6", "display_name": "Opus" },
  "cost": { "total_cost_usd": 0.42 },
  "context_window": {
    "current_usage": {
      "input_tokens": 12000,
      "output_tokens": 2500,
      "cache_creation_input_tokens": 8000,
      "cache_read_input_tokens": 4000
    }
  }
}'

echo "$EVENT2" | bash "$HOOK"

# live.json should now reflect the second event
LIVE2=$(cat "$DEST/live.json")
assert_eq "live.json updated to new session" "test-session-456" "$(echo "$LIVE2" | jq -r '.sid')"
assert_eq "live.json updated model" "claude-opus-4-6" "$(echo "$LIVE2" | jq -r '.model')"
assert_eq "live.json updated cost" "0.42" "$(echo "$LIVE2" | jq -r '.cost')"

JSONL_LINES2=$(wc -l < "$DEST/events.jsonl" | tr -d ' ')
assert_eq "events.jsonl has 2 lines" "2" "$JSONL_LINES2"

# Verify first line still has original data
FIRST_LINE=$(head -1 "$DEST/events.jsonl")
assert_eq "first JSONL line preserved" "test-session-123" "$(echo "$FIRST_LINE" | jq -r '.sid')"

# Verify second line has new data
SECOND_LINE=$(tail -1 "$DEST/events.jsonl")
assert_eq "second JSONL line correct" "test-session-456" "$(echo "$SECOND_LINE" | jq -r '.sid')"

echo ""

# ------------------------------------------------------------------
# Test 3: Missing/null fields — fallback handling
# ------------------------------------------------------------------
printf "${BOLD}Test 3: Missing/null fields use fallbacks${RESET}\n"

EVENT3='{
  "session_id": null,
  "model": {},
  "cost": {},
  "context_window": {
    "current_usage": {}
  }
}'

echo "$EVENT3" | bash "$HOOK"

LIVE3=$(cat "$DEST/live.json")
assert_eq "null session_id → empty string" "" "$(echo "$LIVE3" | jq -r '.sid')"
assert_eq "missing model.id → unknown" "unknown" "$(echo "$LIVE3" | jq -r '.model')"
assert_eq "missing cost → 0" "0" "$(echo "$LIVE3" | jq -r '.cost')"
assert_eq "missing input_tokens → 0" "0" "$(echo "$LIVE3" | jq -r '.in')"
assert_eq "missing output_tokens → 0" "0" "$(echo "$LIVE3" | jq -r '.out')"
assert_eq "missing cache_creation → 0" "0" "$(echo "$LIVE3" | jq -r '.cw')"
assert_eq "missing cache_read → 0" "0" "$(echo "$LIVE3" | jq -r '.cr')"

JSONL_LINES3=$(wc -l < "$DEST/events.jsonl" | tr -d ' ')
assert_eq "events.jsonl has 3 lines" "3" "$JSONL_LINES3"

echo ""

# ------------------------------------------------------------------
# Test 4: Minimal event — completely missing sections
# ------------------------------------------------------------------
printf "${BOLD}Test 4: Minimal event with missing top-level sections${RESET}\n"

EVENT4='{}'

echo "$EVENT4" | bash "$HOOK"

LIVE4=$(cat "$DEST/live.json")
assert_eq "empty event sid → empty" "" "$(echo "$LIVE4" | jq -r '.sid')"
assert_eq "empty event model → unknown" "unknown" "$(echo "$LIVE4" | jq -r '.model')"
assert_eq "empty event cost → 0" "0" "$(echo "$LIVE4" | jq -r '.cost')"
assert_eq "empty event in → 0" "0" "$(echo "$LIVE4" | jq -r '.in')"
assert_eq "all 8 fields present" "8" "$(echo "$LIVE4" | jq 'keys | length')"

echo ""

# ------------------------------------------------------------------
# Test 5: Atomic write — no partial reads
# ------------------------------------------------------------------
printf "${BOLD}Test 5: Atomic write verification${RESET}\n"

# Verify no temp files left behind
TEMP_COUNT=$(find "$DEST" -name 'live.*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no temp files left behind" "0" "$TEMP_COUNT"

# Verify live.json is valid JSON (not truncated)
TOTAL=$((TOTAL + 1))
if echo "$LIVE4" | jq empty 2>/dev/null; then
  PASS=$((PASS + 1))
  printf "${GREEN}  ✓ live.json is valid JSON (not truncated)${RESET}\n"
else
  FAIL=$((FAIL + 1))
  printf "${RED}  ✗ live.json is invalid/truncated JSON${RESET}\n"
fi

echo ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
printf "${BOLD}=== Results: %d/%d passed ===${RESET}\n" "$PASS" "$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}All tests passed!${RESET}\n"
  exit 0
else
  printf "${RED}%d test(s) failed${RESET}\n" "$FAIL"
  exit 1
fi

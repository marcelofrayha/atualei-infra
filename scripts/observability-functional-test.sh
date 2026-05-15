#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
ADMIN_API_KEY="${ADMIN_API_KEY:-dev-secret}"
USERS="${USERS:-5}"
ITERATIONS="${ITERATIONS:-8}"
INCLUDE_ADMIN_RERUN="${INCLUDE_ADMIN_RERUN:-false}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if (( USERS < 1 )); then
  echo "USERS must be at least 1" >&2
  exit 1
fi

if (( USERS > 5 )); then
  echo "USERS is capped at 5 for this functional observability test" >&2
  USERS=5
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local admin="${4:-false}"
  local output_file="$5"
  local curl_args=(
    -sS
    -o /dev/null
    -w "%{http_code} %{time_total} ${method} ${path}\n"
    -X "$method"
    "${BASE_URL}${path}"
    -H "X-Functional-Test: observability"
  )

  if [[ "$admin" == "true" ]]; then
    curl_args+=(-H "X-Admin-Api-Key: ${ADMIN_API_KEY}")
  fi

  if [[ -n "$body" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$body")
  fi

  if ! curl "${curl_args[@]}" >> "$output_file"; then
    printf "000 0.000000 %s %s\n" "$method" "$path" >> "$output_file"
  fi
}

echo "Checking app health at ${BASE_URL}"
curl -fsS "${BASE_URL}/api/v1/health" >/dev/null

laws_json="$(curl -fsS "${BASE_URL}/api/v1/laws")"
mapfile -t law_ids < <(jq -r '.[].id' <<< "$laws_json")
mapfile -t version_ids < <(jq -r '.[].currentVersionId // empty' <<< "$laws_json")

if (( ${#law_ids[@]} == 0 )); then
  echo "No public laws found. Publish at least one law before running this test." >&2
  exit 1
fi

if (( ${#version_ids[@]} == 0 )); then
  echo "No current law versions found. Publish at least one version before running this test." >&2
  exit 1
fi

echo "Starting functional observability test"
echo "  baseUrl=${BASE_URL}"
echo "  users=${USERS}"
echo "  iterationsPerUser=${ITERATIONS}"
echo "  includeAdminRerun=${INCLUDE_ADMIN_RERUN}"
echo "  laws=${#law_ids[@]}"

worker() {
  local user="$1"
  local output_file="$tmp_dir/user-${user}.log"
  local session_id="functional-session-${user}-$(date +%s)"

  for (( iteration = 1; iteration <= ITERATIONS; iteration++ )); do
    local law_index=$(( (user + iteration) % ${#law_ids[@]} ))
    local version_index=$(( (user + iteration) % ${#version_ids[@]} ))
    local law_id="${law_ids[$law_index]}"
    local version_id="${version_ids[$version_index]}"
    local route="/laws/${law_id}"

    request "GET" "/api/v1/health" "" "false" "$output_file"
    request "GET" "/api/v1/laws" "" "false" "$output_file"
    request "GET" "/api/v1/laws/${law_id}" "" "false" "$output_file"
    request "GET" "/api/v1/laws/${law_id}/units?type=ARTICLE&page=0&size=5" "" "false" "$output_file"
    request "GET" "/api/v1/laws/${law_id}/tree?maxDepth=1&includeContent=false" "" "false" "$output_file"
    request "GET" "/api/v1/laws/${law_id}/search?q=direito&limit=5&includeContext=true" "" "false" "$output_file"

    request "POST" "/api/v1/analytics/events" "$(jq -cn \
      --arg anonymousId "functional-user-${user}" \
      --arg sessionId "$session_id" \
      --arg route "$route" \
      --argjson iteration "$iteration" \
      '{eventType:"PAGE_VIEW", anonymousId:$anonymousId, sessionId:$sessionId, route:$route, action:"functional-observability-test", metadata:{iteration:$iteration}}')" \
      "false" "$output_file"

    request "GET" "/api/v1/admin/laws" "" "true" "$output_file"
    request "GET" "/api/v1/admin/laws/${law_id}/versions" "" "true" "$output_file"
    request "GET" "/api/v1/admin/law-versions/${version_id}/quality-report" "" "true" "$output_file"

    if [[ "$INCLUDE_ADMIN_RERUN" == "true" ]]; then
      request "POST" "/api/v1/admin/law-versions/${version_id}/quality-report/rerun" "" "true" "$output_file"
    fi
  done
}

for (( user = 1; user <= USERS; user++ )); do
  worker "$user" &
done

wait

cat "$tmp_dir"/user-*.log > "$tmp_dir/results.log"

total_requests="$(wc -l < "$tmp_dir/results.log" | tr -d ' ')"
failed_requests="$(awk '$1 < 200 || $1 >= 400 { count++ } END { print count + 0 }' "$tmp_dir/results.log")"

echo
echo "Functional observability test finished"
echo "  totalRequests=${total_requests}"
echo "  failedRequests=${failed_requests}"
echo
echo "Status counts:"
awk '{ count[$1]++ } END { for (status in count) print "  " status, count[status] }' "$tmp_dir/results.log" | sort
echo
echo "Slowest requests:"
sort -k2 -nr "$tmp_dir/results.log" | head -10 | awk '{ printf "  %s %ss %s %s\n", $1, $2, $3, $4 }'
echo
echo "Next checks:"
echo "  Grafana:    http://localhost:3000/dashboards"
echo "  Prometheus: http://localhost:9090"
echo "  Tempo:      http://localhost:3000/explore"
echo "  Logs:       http://localhost:3000/explore?left=%7B%22datasource%22:%22loki%22%7D"

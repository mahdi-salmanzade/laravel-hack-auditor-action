#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Map the provider input to the correct environment variable name
# ---------------------------------------------------------------------------
case "${INPUT_PROVIDER}" in
  anthropic)
    export ANTHROPIC_API_KEY="${INPUT_API_KEY}"
    ;;
  openai)
    export OPENAI_API_KEY="${INPUT_API_KEY}"
    ;;
  gemini)
    export GEMINI_API_KEY="${INPUT_API_KEY}"
    ;;
  *)
    echo "::error::Unknown provider '${INPUT_PROVIDER}'. Supported: anthropic, openai, gemini."
    exit 1
    ;;
esac

export HACK_AUDITOR_AI_PROVIDER="${INPUT_PROVIDER}"

if [ -n "${INPUT_MODEL}" ]; then
  export HACK_AUDITOR_AI_MODEL="${INPUT_MODEL}"
fi

# ---------------------------------------------------------------------------
# Build the artisan command
# ---------------------------------------------------------------------------
CMD=(php artisan hack:scan --json --diff --force --no-interaction)

if [ -n "${INPUT_SEVERITY}" ]; then
  CMD+=(--severity="${INPUT_SEVERITY}")
fi

if [ -n "${INPUT_BASE_BRANCH}" ]; then
  CMD+=(--base="${INPUT_BASE_BRANCH}")
fi

if [ -n "${INPUT_SCAN_PATH}" ]; then
  CMD+=(--path="${INPUT_SCAN_PATH}")
fi

if [ -n "${INPUT_TOKEN_LIMIT}" ]; then
  CMD+=(--limit="${INPUT_TOKEN_LIMIT}")
fi

# ---------------------------------------------------------------------------
# Run the scan
# ---------------------------------------------------------------------------
RESULTS_FILE="${GITHUB_WORKSPACE}/.hack-auditor-results.json"
echo "Running: ${CMD[*]}"

set +e
"${CMD[@]}" > "${RESULTS_FILE}" 2>/dev/null
SCAN_EXIT=$?
set -e

# Handle empty output
if [ ! -s "${RESULTS_FILE}" ]; then
  echo "::warning::Scan produced no output (exit code: ${SCAN_EXIT}). No changed PHP files, or the scan errored."
  echo "score=100" >> "$GITHUB_OUTPUT"
  echo "total=0" >> "$GITHUB_OUTPUT"
  echo "critical=0" >> "$GITHUB_OUTPUT"
  echo "high=0" >> "$GITHUB_OUTPUT"
  echo "medium=0" >> "$GITHUB_OUTPUT"
  echo "low=0" >> "$GITHUB_OUTPUT"
  echo "json_path=${RESULTS_FILE}" >> "$GITHUB_OUTPUT"
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse results and export outputs
# ---------------------------------------------------------------------------
SCORE=$(jq -r '.overall_score // 100' "${RESULTS_FILE}")
TOTAL=$(jq -r '.counts.total // 0' "${RESULTS_FILE}")
CRITICAL=$(jq -r '.counts.critical // 0' "${RESULTS_FILE}")
HIGH=$(jq -r '.counts.high // 0' "${RESULTS_FILE}")
MEDIUM=$(jq -r '.counts.medium // 0' "${RESULTS_FILE}")
LOW=$(jq -r '.counts.low // 0' "${RESULTS_FILE}")

echo "score=${SCORE}" >> "$GITHUB_OUTPUT"
echo "total=${TOTAL}" >> "$GITHUB_OUTPUT"
echo "critical=${CRITICAL}" >> "$GITHUB_OUTPUT"
echo "high=${HIGH}" >> "$GITHUB_OUTPUT"
echo "medium=${MEDIUM}" >> "$GITHUB_OUTPUT"
echo "low=${LOW}" >> "$GITHUB_OUTPUT"
echo "json_path=${RESULTS_FILE}" >> "$GITHUB_OUTPUT"

# ---------------------------------------------------------------------------
# Emit GitHub annotations (show inline in "Files changed" tab)
# ---------------------------------------------------------------------------
jq -c '.vulnerabilities[]' "${RESULTS_FILE}" | while IFS= read -r vuln; do
  FILE=$(echo "${vuln}" | jq -r '.location')
  LINE=$(echo "${vuln}" | jq -r '.line')
  SEVERITY=$(echo "${vuln}" | jq -r '.severity')
  TYPE_LABEL=$(echo "${vuln}" | jq -r '.type_label')
  DESC=$(echo "${vuln}" | jq -r '.description' | head -c 500)

  case "${SEVERITY}" in
    critical|high) LEVEL="error" ;;
    medium)        LEVEL="warning" ;;
    *)             LEVEL="notice" ;;
  esac

  echo "::${LEVEL} file=${FILE},line=${LINE},title=${TYPE_LABEL}::${DESC}"
done

# ---------------------------------------------------------------------------
# Fail the step if findings exceed the threshold
# ---------------------------------------------------------------------------
if [ "${INPUT_FAIL_ON}" != "none" ] && [ "${INPUT_FAIL_ON}" != "" ]; then
  SHOULD_FAIL=0

  case "${INPUT_FAIL_ON}" in
    low)
      [ "${TOTAL}" -gt 0 ] && SHOULD_FAIL=1
      ;;
    medium)
      ABOVE=$(( MEDIUM + HIGH + CRITICAL ))
      [ "${ABOVE}" -gt 0 ] && SHOULD_FAIL=1
      ;;
    high)
      ABOVE=$(( HIGH + CRITICAL ))
      [ "${ABOVE}" -gt 0 ] && SHOULD_FAIL=1
      ;;
    critical)
      [ "${CRITICAL}" -gt 0 ] && SHOULD_FAIL=1
      ;;
  esac

  if [ "${SHOULD_FAIL}" -eq 1 ]; then
    echo "::error::Findings at or above '${INPUT_FAIL_ON}' severity detected — failing the check."
    exit 1
  fi
fi

echo "Scan complete. Score: ${SCORE}/100, Findings: ${TOTAL}"

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# import-flows.sh
# Runs every time the Codespace starts (postStartCommand).
# Waits for Kestra to be ready, then pushes every .yml file found under
# ./kestra/flows/ into Kestra via its REST API.
#
# Each flow file must declare a valid `namespace` and `id` at the top level.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

KESTRA_HOST="${KESTRA_HOST:-http://kestra:8080}"
FLOWS_DIR="/workspace/kestra/flows"
MAX_WAIT=120   # seconds to wait for Kestra to become healthy
POLL_INTERVAL=5

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[flows]${NC} $*"; }
warn()  { echo -e "${YELLOW}[flows]${NC} $*"; }
error() { echo -e "${RED}[flows]${NC} $*"; }

# ── 1. Wait for Kestra health endpoint ───────────────────────────────────────
info "Waiting for Kestra at ${KESTRA_HOST} (timeout: ${MAX_WAIT}s)..."

elapsed=0
until curl -sf "${KESTRA_HOST}/api/v1/health" > /dev/null 2>&1; do
  if (( elapsed >= MAX_WAIT )); then
    error "Kestra did not become healthy within ${MAX_WAIT}s. Skipping flow import."
    error "Start Kestra manually with: docker compose up -d kestra"
    exit 0   # non-fatal: let the workspace open anyway
  fi
  sleep "${POLL_INTERVAL}"
  elapsed=$(( elapsed + POLL_INTERVAL ))
done

info "Kestra is healthy."

# ── 2. Discover flow files ────────────────────────────────────────────────────
if [[ ! -d "${FLOWS_DIR}" ]]; then
  warn "Flows directory not found: ${FLOWS_DIR}"
  warn "Create it and add .yml flow files, then re-run: bash scripts/import-flows.sh"
  exit 0
fi

mapfile -t FLOW_FILES < <(find "${FLOWS_DIR}" -name "*.yml" -o -name "*.yaml" | sort)

if [[ ${#FLOW_FILES[@]} -eq 0 ]]; then
  warn "No flow files found in ${FLOWS_DIR}"
  warn "Add a flow .yml and re-run this script to import it."
  exit 0
fi

info "Found ${#FLOW_FILES[@]} flow file(s) to import."

# ── 3. Import each flow ───────────────────────────────────────────────────────
SUCCESS=0
FAILED=0

for flow_file in "${FLOW_FILES[@]}"; do
  filename=$(basename "${flow_file}")

  http_status=$(curl -s -o /tmp/kestra-import-response.json -w "%{http_code}" \
    -X POST "${KESTRA_HOST}/api/v1/flows" \
    -H "Content-Type: application/x-yaml" \
    --data-binary "@${flow_file}")

  if [[ "${http_status}" == "200" || "${http_status}" == "201" ]]; then
    info "  ✓ Imported: ${filename}"
    SUCCESS=$(( SUCCESS + 1 ))
  elif [[ "${http_status}" == "409" ]]; then
    # Flow already exists — update it with PUT
    # Extract namespace and id from the YAML for the PUT endpoint
    namespace=$(grep -m1 "^namespace:" "${flow_file}" | awk '{print $2}' | tr -d '"')
    flow_id=$(grep -m1 "^id:" "${flow_file}" | awk '{print $2}' | tr -d '"')

    if [[ -n "${namespace}" && -n "${flow_id}" ]]; then
      put_status=$(curl -s -o /tmp/kestra-import-response.json -w "%{http_code}" \
        -X PUT "${KESTRA_HOST}/api/v1/flows/${namespace}/${flow_id}" \
        -H "Content-Type: application/x-yaml" \
        --data-binary "@${flow_file}")

      if [[ "${put_status}" == "200" ]]; then
        info "  ↻ Updated:  ${filename}"
        SUCCESS=$(( SUCCESS + 1 ))
      else
        error "  ✗ Failed to update ${filename} (HTTP ${put_status})"
        cat /tmp/kestra-import-response.json 2>/dev/null || true
        FAILED=$(( FAILED + 1 ))
      fi
    else
      error "  ✗ Cannot parse namespace/id from ${filename} — skipping update"
      FAILED=$(( FAILED + 1 ))
    fi
  else
    error "  ✗ Failed to import ${filename} (HTTP ${http_status})"
    cat /tmp/kestra-import-response.json 2>/dev/null || true
    FAILED=$(( FAILED + 1 ))
  fi
done

# ── 4. Summary ────────────────────────────────────────────────────────────────
echo ""
info "Import complete: ${SUCCESS} succeeded, ${FAILED} failed."
info "Kestra UI: ${KESTRA_HOST}"

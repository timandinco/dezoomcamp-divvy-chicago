#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# post-create.sh
# Runs ONCE when the Codespace is first created (postCreateCommand).
#
# Order of operations matters here:
#   1. Ensure ./secrets/gcp-key.json exists BEFORE docker compose tries to
#      bind-mount it into the kestra container. If the file is missing Docker
#      will error out when Kestra starts.
#   2. Write the dbt profiles.yml.
#   3. Copy .env.example -> .env if not already present.
#   4. Install pre-commit hooks.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
error() { echo -e "${RED}[error]${NC} $*"; }

# ── 1. GCP credentials ────────────────────────────────────────────────────────
# MUST run before `docker compose up` because kestra bind-mounts this file.
# A missing bind-mount source causes Docker to error on container start.
info "Checking GCP credentials..."
mkdir -p /workspace/secrets

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ]]; then
  info "Writing GCP key from Codespace secret GOOGLE_APPLICATION_CREDENTIALS_JSON..."
  echo "${GOOGLE_APPLICATION_CREDENTIALS_JSON}" > /workspace/secrets/gcp-key.json
  chmod 600 /workspace/secrets/gcp-key.json
  info "GCP key written to ./secrets/gcp-key.json"
else
  if [[ ! -f /workspace/secrets/gcp-key.json ]]; then
    # Write an empty JSON object as a placeholder so the Docker bind-mount
    # target exists. Kestra will start but GCP calls will fail until you
    # replace this with a real key.
    echo '{}' > /workspace/secrets/gcp-key.json
    warn "No GCP key found. Created empty placeholder at ./secrets/gcp-key.json"
    warn "Replace it with a real service-account key, then restart Kestra:"
    warn "  docker compose restart kestra"
  else
    info "Found existing ./secrets/gcp-key.json"
  fi
  warn "To authenticate interactively: gcloud auth application-default login"
fi

# ── 2. .env file ──────────────────────────────────────────────────────────────
if [[ ! -f /workspace/.env ]]; then
  info "Copying .env.example to .env"
  cp /workspace/.env.example /workspace/.env
  warn "Edit .env and set GCP_PROJECT_ID, GCP_BUCKET, BQ_DATASET"
else
  info ".env already exists — skipping"
fi

# ── 3. dbt profiles.yml ───────────────────────────────────────────────────────
info "Setting up dbt profiles..."
mkdir -p ~/.dbt

if [[ ! -f ~/.dbt/profiles.yml ]]; then
  GCP_PROJECT="${GCP_PROJECT_ID:-my-gcp-project}"
  BQ_DATASET_VAL="${BQ_DATASET:-divvy_raw}"
  GCP_LOC="${GCP_LOCATION:-US}"

  cat > ~/.dbt/profiles.yml <<PROFILE
divvy_dbt:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: service-account
      project: ${GCP_PROJECT}
      dataset: ${BQ_DATASET_VAL}
      location: ${GCP_LOC}
      keyfile: /workspace/secrets/gcp-key.json
      threads: 4
      timeout_seconds: 300
      priority: interactive
PROFILE
  info "dbt profiles.yml written to ~/.dbt/profiles.yml"
else
  info "~/.dbt/profiles.yml already exists — skipping"
fi

# ── 4. pre-commit hooks ───────────────────────────────────────────────────────
if [[ -f /workspace/.pre-commit-config.yaml ]]; then
  info "Installing pre-commit hooks..."
  cd /workspace && pre-commit install
fi

# ── 5. Tool version summary ───────────────────────────────────────────────────
info "Installed versions:"
python --version
dbt --version 2>/dev/null | head -1 || true
gcloud --version 2>/dev/null | head -1 || true

echo ""
echo -e "${GREEN}Post-create setup complete.${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Update .env with your real GCP_PROJECT_ID, GCP_BUCKET, BQ_DATASET"
echo "  2. Add a valid service-account key at ./secrets/gcp-key.json"
echo "     (or set the GOOGLE_APPLICATION_CREDENTIALS_JSON Codespace secret)"
echo "  3. Kestra UI will be available at http://localhost:8080 once it starts"
echo "     (can take 60-90 s on first boot while it pulls the latest-full image)"

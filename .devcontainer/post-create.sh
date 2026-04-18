#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# post-create.sh
# Runs ONCE when a Codespace is first created.
# Sets up GCP credentials, dbt profile, and local tooling.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[setup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[error]${NC} $*"; }

# ── 1. GCP credentials ────────────────────────────────────────────────────────
info "Checking GCP credentials..."

mkdir -p /workspace/secrets

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ]]; then
  # Codespace Secret: paste the full JSON content of your service-account key
  # as the secret GOOGLE_APPLICATION_CREDENTIALS_JSON
  info "Writing GCP key from Codespace secret..."
  echo "${GOOGLE_APPLICATION_CREDENTIALS_JSON}" > /workspace/secrets/gcp-key.json
  chmod 600 /workspace/secrets/gcp-key.json
  info "GCP key written to /workspace/secrets/gcp-key.json"
else
  warn "GOOGLE_APPLICATION_CREDENTIALS_JSON secret not set."
  warn "To authenticate manually, run one of:"
  warn "  gcloud auth application-default login"
  warn "  -- or place your service-account key at ./secrets/gcp-key.json"

  # Create a placeholder so Docker volume mounts don't fail
  if [[ ! -f /workspace/secrets/gcp-key.json ]]; then
    echo '{}' > /workspace/secrets/gcp-key.json
    warn "Created empty placeholder at ./secrets/gcp-key.json"
  fi
fi

# ── 2. .env file ──────────────────────────────────────────────────────────────
if [[ ! -f /workspace/.env ]]; then
  info "Copying .env.example → .env (fill in your project values)"
  cp /workspace/.env.example /workspace/.env
fi

# ── 3. dbt profiles directory ─────────────────────────────────────────────────
info "Setting up dbt profiles..."
mkdir -p ~/.dbt

if [[ ! -f ~/.dbt/profiles.yml ]]; then
  GCP_PROJECT="${GCP_PROJECT_ID:-my-gcp-project}"
  BQ_DATASET="${BQ_DATASET:-divvy_raw}"
  GCP_LOCATION="${GCP_LOCATION:-US}"

  cat > ~/.dbt/profiles.yml <<EOF
divvy_dbt:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: service-account
      project: ${GCP_PROJECT}
      dataset: ${BQ_DATASET}
      location: ${GCP_LOCATION}
      keyfile: /workspace/secrets/gcp-key.json
      threads: 4
      timeout_seconds: 300
      priority: interactive
EOF
  info "dbt profiles.yml written to ~/.dbt/profiles.yml"
else
  info "dbt profiles.yml already exists — skipping"
fi

# ── 4. pre-commit hooks ───────────────────────────────────────────────────────
if [[ -f /workspace/.pre-commit-config.yaml ]]; then
  info "Installing pre-commit hooks..."
  cd /workspace && pre-commit install
fi

# ── 5. Verify tooling ─────────────────────────────────────────────────────────
info "Installed tool versions:"
python --version
dbt --version 2>/dev/null | head -1
gcloud --version | head -1

info "Post-create setup complete."
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Fill in .env with your GCP_PROJECT_ID, GCP_BUCKET, BQ_DATASET"
echo "  2. Ensure ./secrets/gcp-key.json contains a valid service-account key"
echo "  3. Add Kestra flows to ./kestra/flows/"
echo "  4. Kestra UI → http://localhost:8080"

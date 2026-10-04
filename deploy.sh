#!/usr/bin/env bash
# =============================================================================
# Antigravity Enterprise Gateway (LiteLLM Proxy) — Turnkey Deployment Script
# =============================================================================
# Usage:
#   ./deploy.sh --project <GCP_PROJECT_ID> [options]
#
# Options:
#   -p, --project <ID>         GCP project to deploy into (default: gcloud config project)
#   -r, --region <REGION>      Cloud Run region (default: us-central1)
#   -k, --api-key <KEY>        Use / rotate to this gateway API key (default: reuse or generate)
#   -s, --service <NAME>       Cloud Run service name (default: antigravity-enterprise-gateway)
#   -m, --min-instances <N>    Keep N warm instances to avoid cold starts (default: 0)
#   -S, --sync-models          Skip Cloud Run build; probe active models on existing gateway
#                              and regenerate admin_settings.json + gateway.env (~5 sec)
#   -I, --install-client       After generating the client files, run ./setup-client.sh on
#                              THIS machine (one-time setup; asks for sudo once)
#   -h, --help                 Show this help
#
# What this script does automatically:
#   0. Pre-flight checks (required tools, gcloud login)
#   1. Resolves the target GCP project
#   2. Enables required GCP APIs (Cloud Run, Vertex AI / GEAP, Cloud Build, Secret Manager)
#   3. Creates a dedicated least-privilege IAM Service Account
#   4. Stores (or generates) the gateway API key in Google Cloud Secret Manager
#   5. Deploys the upstream open-source LiteLLM Proxy container to Cloud Run
#   6. Probes every model in `config.yaml` to check Vertex AI / GEAP Model Garden activation
#      (with --sync-models, it also warns if local config.yaml has models the running
#      gateway doesn't know about yet, because config.yaml is baked into the container)
#   7. Generates `admin_settings.json` and `gateway.env` with ONLY the active models
#   8. Runs end-to-end verification tests (Health, Auth, Gemini, Claude, Tool Calls)
#
# Safe to re-run at any time: every step is idempotent.
# =============================================================================

set -euo pipefail

# Always run from the folder containing this script (Dockerfile, config.yaml, ...)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure gcloud is on PATH if installed in ~/google-cloud-sdk/bin
if ! command -v gcloud >/dev/null 2>&1 && [[ -x "${HOME}/google-cloud-sdk/bin/gcloud" ]]; then
  export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SERVICE_NAME="${CLOUD_RUN_SERVICE:-agy-llm-gateway}"
CLOUD_RUN_REGION="us-central1"
VERTEX_LOCATION="global"
SA_NAME="antigravity-gateway-sa"
SECRET_NAME="antigravity-gateway-api-key"
MIN_INSTANCES="0"
SYNC_MODELS_ONLY="false"
INSTALL_CLIENT="false"
PROJECT_ID="${GCP_PROJECT_ID:-}"
CUSTOM_API_KEY="${LITELLM_MASTER_KEY:-${GATEWAY_API_KEY:-}}"

usage() { sed -n '5,18p' "${SCRIPT_DIR}/deploy.sh" | sed 's/^# \{0,1\}//'; }
die() { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)       PROJECT_ID="${2:?missing value for $1}"; shift 2 ;;
    --project=*)        PROJECT_ID="${1#*=}"; shift 1 ;;
    -r|--region)        CLOUD_RUN_REGION="${2:?missing value for $1}"; shift 2 ;;
    --region=*)         CLOUD_RUN_REGION="${1#*=}"; shift 1 ;;
    -k|--api-key)       CUSTOM_API_KEY="${2:?missing value for $1}"; shift 2 ;;
    --api-key=*)        CUSTOM_API_KEY="${1#*=}"; shift 1 ;;
    -s|--service)       SERVICE_NAME="${2:?missing value for $1}"; shift 2 ;;
    --service=*)        SERVICE_NAME="${1#*=}"; shift 1 ;;
    -m|--min-instances) MIN_INSTANCES="${2:?missing value for $1}"; shift 2 ;;
    --min-instances=*)  MIN_INSTANCES="${1#*=}"; shift 1 ;;
    -S|--sync-models)   SYNC_MODELS_ONLY="true"; shift 1 ;;
    -I|--install-client) INSTALL_CLIENT="true"; shift 1 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; die "Unknown argument: $1" ;;
  esac
done

echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${BLUE}${BOLD}   Antigravity Enterprise Gateway — LiteLLM Proxy on Cloud Run        ${NC}"
echo -e "${BLUE}${BOLD}======================================================================${NC}"

# 0. Pre-flight checks
for tool in gcloud curl openssl sed awk; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed. See README.md → Prerequisites."
done
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1 || true)
[[ -n "$ACTIVE_ACCOUNT" ]] || die "You are not logged in to gcloud. Run: ${BOLD}gcloud auth login${NC}"
[[ "$MIN_INSTANCES" =~ ^[0-9]+$ ]] || die "--min-instances must be a non-negative integer."

# 1. Resolve GCP Project ID
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  die "No GCP Project ID specified. Run: ${BOLD}./deploy.sh --project YOUR_GCP_PROJECT_ID${NC}"
fi
gcloud projects describe "$PROJECT_ID" --format="value(projectId)" >/dev/null 2>&1 \
  || die "Project '${PROJECT_ID}' not found or ${ACTIVE_ACCOUNT} has no access to it."

echo -e "${GREEN}[1/8] Target GCP Project:${NC} ${BOLD}${PROJECT_ID}${NC} as ${ACTIVE_ACCOUNT} (Cloud Run: ${CLOUD_RUN_REGION}, Vertex AI / GEAP: ${VERTEX_LOCATION})"

wait_for_health() {
  local code=""
  for _ in $(seq 1 12); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "${SERVICE_URL}/health/liveliness" || true)
    [[ "$code" == "200" || "$code" == "403" ]] && break
    sleep 5
  done
  echo "$code"
}

check_gateway_health() {
  local health_code
  health_code=$(wait_for_health)
  if [[ "$health_code" == "403" ]]; then
    echo -e "${YELLOW}      Cloud Run returned 403 (likely org policy blocking public access). Disabling the invoker IAM check...${NC}"
    gcloud run services update "$SERVICE_NAME" \
      --project="$PROJECT_ID" \
      --region="$CLOUD_RUN_REGION" \
      --no-invoker-iam-check \
      --quiet
    health_code=$(wait_for_health)
  fi
  [[ "$health_code" == "200" ]] || die "Gateway health check returned HTTP ${health_code}. See README.md → Troubleshooting."
}

if [[ "$SYNC_MODELS_ONLY" == "true" ]]; then
  echo -e "${YELLOW}[2-5/8] --sync-models enabled: skipping Cloud Run build and reusing deployed gateway...${NC}"
  SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --project="$PROJECT_ID" \
    --region="$CLOUD_RUN_REGION" \
    --format="value(status.url)" 2>/dev/null || true)
  [[ -n "$SERVICE_URL" ]] || die "Cloud Run service '${SERVICE_NAME}' not found in ${PROJECT_ID} (${CLOUD_RUN_REGION}). Run ./deploy.sh without --sync-models first."

  ACTIVE_API_KEY="${CUSTOM_API_KEY:-$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID" 2>/dev/null || true)}"
  [[ -n "$ACTIVE_API_KEY" ]] || die "Could not read API key from Secret Manager (${SECRET_NAME})."

  check_gateway_health
else
  # 2. Enable Required Google Cloud APIs
  echo -e "${GREEN}[2/8] Enabling required Google Cloud APIs (first run can take ~1 min)...${NC}"
  gcloud services enable \
    run.googleapis.com \
    aiplatform.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet

  # 3. Create Dedicated Least-Privilege Service Account
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  echo -e "${GREEN}[3/8] Configuring least-privilege Service Account (${SA_EMAIL})...${NC}"

  if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$SA_NAME" \
      --display-name="Antigravity LiteLLM Gateway Service Account" \
      --project="$PROJECT_ID" \
      --quiet
  fi

  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/aiplatform.user" \
    --condition=None \
    --quiet >/dev/null

  # 4. Provision the Gateway API Key (LiteLLM Master Key) in Secret Manager
  echo -e "${GREEN}[4/8] Provisioning gateway API key in Secret Manager (${SECRET_NAME})...${NC}"

  if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets create "$SECRET_NAME" \
      --replication-policy="automatic" \
      --project="$PROJECT_ID" \
      --quiet
  fi

  EXISTING_KEY=$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID" 2>/dev/null || true)
  NEW_VERSION_ADDED=false

  if [[ -n "$CUSTOM_API_KEY" && "$CUSTOM_API_KEY" != "$EXISTING_KEY" ]]; then
    ACTIVE_API_KEY="$CUSTOM_API_KEY"
    printf "%s" "$ACTIVE_API_KEY" | gcloud secrets versions add "$SECRET_NAME" \
      --data-file=- --project="$PROJECT_ID" --quiet >/dev/null
    NEW_VERSION_ADDED=true
    echo -e "      Rotated: stored the provided API key as the latest Secret Manager version."
  elif [[ -n "$EXISTING_KEY" ]]; then
    ACTIVE_API_KEY="$EXISTING_KEY"
    echo -e "      Reusing existing API key from Secret Manager."
  else
    ACTIVE_API_KEY="sk-agy-$(openssl rand -hex 32)"
    printf "%s" "$ACTIVE_API_KEY" | gcloud secrets versions add "$SECRET_NAME" \
      --data-file=- --project="$PROJECT_ID" --quiet >/dev/null
    NEW_VERSION_ADDED=true
    echo -e "      Generated a new random 256-bit API key and stored it in Secret Manager."
  fi

  gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --project="$PROJECT_ID" \
    --quiet >/dev/null

  # 5. Deploy the LiteLLM Proxy Container (upstream open-source image) to Cloud Run
  echo -e "${GREEN}[5/8] Building and deploying LiteLLM Proxy (${SERVICE_NAME}) to Cloud Run (~3-5 min)...${NC}"
  # Network access is public (the CLI must reach it from anywhere); every model
  # request is authenticated by LiteLLM using the API key from Secret Manager.
  gcloud run deploy "$SERVICE_NAME" \
    --source . \
    --project="$PROJECT_ID" \
    --region="$CLOUD_RUN_REGION" \
    --service-account="$SA_EMAIL" \
    --allow-unauthenticated \
    --memory="1Gi" \
    --cpu="2" \
    --cpu-boost \
    --min-instances="$MIN_INSTANCES" \
    --timeout="600" \
    --set-env-vars="GCP_PROJECT_ID=${PROJECT_ID},VERTEXAI_PROJECT=${PROJECT_ID},VERTEXAI_LOCATION=${VERTEX_LOCATION}" \
    --set-secrets="LITELLM_MASTER_KEY=${SECRET_NAME}:latest,GATEWAY_API_KEY=${SECRET_NAME}:latest" \
    --quiet

  SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --project="$PROJECT_ID" \
    --region="$CLOUD_RUN_REGION" \
    --format="value(status.url)")

  # Organizations with the "Domain Restricted Sharing" policy block `allUsers`
  # IAM bindings, so Cloud Run answers 403 before LiteLLM ever sees the request.
  # Fallback: disable the Cloud Run invoker IAM check (LiteLLM still enforces the API key).
  check_gateway_health

  # Once the new revision is serving, disable superseded keys so they stop working.
  if [[ "$NEW_VERSION_ADDED" == "true" ]]; then
    LATEST_VERSION=$(gcloud secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" \
      --filter="state=ENABLED" --sort-by="~createTime" --limit=1 --format="value(name.basename())")
    for v in $(gcloud secrets versions list "$SECRET_NAME" --project="$PROJECT_ID" \
        --filter="state=ENABLED" --format="value(name.basename())"); do
      if [[ "$v" != "$LATEST_VERSION" ]]; then
        gcloud secrets versions disable "$v" --secret="$SECRET_NAME" --project="$PROJECT_ID" --quiet >/dev/null
        echo -e "      Disabled superseded API key (Secret Manager version ${v})."
      fi
    done
  fi
fi

# 6. Probe Model Activation Status in Vertex AI / GEAP Model Garden
#    Only models listed under `model_list` in config.yaml are probed. Model Garden has
#    no "list everything I enabled" API, so a model enabled there but missing from
#    config.yaml will never show up until it is added to config.yaml and redeployed.
echo -e "${GREEN}[6/8] Checking activation of models listed in config.yaml on Vertex AI / GEAP Model Garden (${PROJECT_ID})...${NC}"
mapfile -t CONFIGURED_MODELS < <(
  awk '/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*/ {
    line=$0
    sub(/.*model_name:[[:space:]]*/, "", line)
    sub(/[[:space:]#].*/, "", line)
    gsub(/["\047]/, "", line)
    if (line != "") print line
  }' config.yaml
)

[[ "${#CONFIGURED_MODELS[@]}" -gt 0 ]] || die "No models found under 'model_list' in config.yaml."

PROBE_MODELS=("${CONFIGURED_MODELS[@]}")
NOT_DEPLOYED_MODELS=()

# --sync-models reuses the running container, whose config.yaml was baked in at the
# last full deploy. Detect local edits that were never deployed (e.g. a newly added
# Claude model) so they're reported accurately instead of as "not enabled".
if [[ "$SYNC_MODELS_ONLY" == "true" ]]; then
  DEPLOYED_JSON=$(curl -s --max-time 15 "${SERVICE_URL}/v1/models" \
    -H "Authorization: Bearer ${ACTIVE_API_KEY}" || true)
  mapfile -t DEPLOYED_MODELS < <(
    printf '%s' "$DEPLOYED_JSON" \
      | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed 's/.*"\([^"]*\)"$/\1/'
  )
  if [[ "${#DEPLOYED_MODELS[@]}" -gt 0 ]]; then
    PROBE_MODELS=()
    for m in "${CONFIGURED_MODELS[@]}"; do
      if printf '%s\n' "${DEPLOYED_MODELS[@]}" | grep -qxF -- "$m"; then
        PROBE_MODELS+=("$m")
      else
        NOT_DEPLOYED_MODELS+=("$m")
      fi
    done
  else
    echo -e "  ${YELLOW}Warning:${NC} could not read the deployed model list (${SERVICE_URL}/v1/models); probing local config.yaml as-is."
  fi
fi

ACTIVE_MODELS=()
INACTIVE_MODELS=()

for m in ${PROBE_MODELS[@]+"${PROBE_MODELS[@]}"}; do
  # Probe with fallbacks=[] and num_retries=0 so a model with 0 quota or not enabled
  # in Model Garden cannot silently fall back to another model and report ACTIVE.
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 25 -X POST \
    "${SERVICE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${ACTIVE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${m}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}],\"max_tokens\":5,\"fallbacks\":[],\"num_retries\":0}" || true)
  HTTP_CODE="${HTTP_CODE:-000}"
  if [[ "$HTTP_CODE" == "200" ]]; then
    ACTIVE_MODELS+=("$m")
    echo -e "  ${GREEN}✓ ACTIVE:${NC}       ${BOLD}${m}${NC} (verified on Vertex AI / GEAP)"
  elif [[ "$HTTP_CODE" == "429" ]]; then
    INACTIVE_MODELS+=("$m")
    echo -e "  ${YELLOW}○ INACTIVE:${NC}     ${BOLD}${m}${NC} (HTTP 429 — enabled in Model Garden, but quota is 0 or exhausted in ${PROJECT_ID}; skipping from client list)"
  else
    INACTIVE_MODELS+=("$m")
    echo -e "  ${YELLOW}○ INACTIVE:${NC}     ${BOLD}${m}${NC} (HTTP ${HTTP_CODE} — not enabled in Model Garden; skipping from client list)"
  fi
done

for m in ${NOT_DEPLOYED_MODELS[@]+"${NOT_DEPLOYED_MODELS[@]}"}; do
  echo -e "  ${RED}✗ NOT DEPLOYED:${NC} ${BOLD}${m}${NC} (in local config.yaml, but not in the running gateway yet)"
done

if [[ "${#INACTIVE_MODELS[@]}" -gt 0 ]]; then
  echo -e ""
  echo -e "  ${YELLOW}Note:${NC} To activate inactive Partner models (${INACTIVE_MODELS[*]}):"
  echo -e "    • If HTTP 404/403: enable the model card in Model Garden: ${BOLD}https://console.cloud.google.com/vertex-ai/model-garden?project=${PROJECT_ID}${NC}"
  echo -e "    • If HTTP 429: request non-zero quota for the base model in IAM & Admin → Quotas: ${BOLD}https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}${NC}"
  echo -e "    • Then refresh your local config in ~5s (no redeploy needed): ${BOLD}./deploy.sh --project ${PROJECT_ID} --service ${SERVICE_NAME} --sync-models${NC}"
fi

if [[ "${#NOT_DEPLOYED_MODELS[@]}" -gt 0 ]]; then
  echo -e ""
  echo -e "  ${RED}${BOLD}Action required:${NC} config.yaml changed since the last full deploy (${NOT_DEPLOYED_MODELS[*]})."
  echo -e "    --sync-models can't add new models: config.yaml is baked into the Cloud Run container."
  echo -e "    Run a full deploy (~3-5 min): ${BOLD}./deploy.sh --project ${PROJECT_ID} --service ${SERVICE_NAME}${NC}"
fi

if [[ "${#ACTIVE_MODELS[@]}" -eq 0 ]]; then
  echo -e "  ${YELLOW}Warning: No models responded with HTTP 200 during probe; falling back to all deployed models in config.yaml.${NC}"
  ACTIVE_MODELS=(${PROBE_MODELS[@]+"${PROBE_MODELS[@]}"})
  [[ "${#ACTIVE_MODELS[@]}" -gt 0 ]] || ACTIVE_MODELS=("${CONFIGURED_MODELS[@]}")
fi

# 7. Generate Local admin_settings.json AND gateway.env with ONLY active models
echo -e "${GREEN}[7/8] Generating admin_settings.json and gateway.env (${#ACTIVE_MODELS[@]} active models)...${NC}"

model_display_name() {
  case "$1" in
    gemini-3.8-flash)          echo "Claude Sonnet 5" ;;
    gemini-3.7-flash)          echo "Claude Opus 5.5" ;;
    gemini-3.1-pro-preview)    echo "Gemini 3.1 Pro" ;;
    gemini-2.5-pro)            echo "Gemini 2.5 Pro" ;;
    gemini-2.5-flash)          echo "Gemini 2.5 Flash" ;;
    claude-sonnet-5)           echo "Claude Sonnet 5" ;;
    claude-opus-5)             echo "Claude Opus 5" ;;
    claude-opus-5-5)           echo "Claude Opus 5.5" ;;
    claude-fable-5)            echo "Claude Fable 5" ;;
    claude-sonnet-4-6)         echo "Claude Sonnet 4.6" ;;
    claude-opus-4-6)           echo "Claude Opus 4.6" ;;
    claude-haiku-4-5@20251001) echo "Claude Haiku 4.5" ;;
    *)                         echo "$1" ;;
  esac
}

# Antigravity CLI (`agy` v1.2.16) only sends native tools for models in its built-in catalog
# (gemini-3.8-flash, gemini-3.7-flash, gemini-3.1-pro-preview). Partner model IDs (claude-*)
# receive ToolFormatterType=4 (tools: null) causing the model to hallucinate fake text tool calls.
# Therefore, only expose tool-capable alias IDs to agy. Direct claude-* routes remain in config.yaml
# for non-agy clients (curl / OpenAI SDK), but are not advertised to agy.
AGY_ALLOWED_MODELS=("gemini-3.8-flash" "gemini-3.7-flash" "gemini-3.1-pro-preview")
AGY_MODELS=()
for m in "${AGY_ALLOWED_MODELS[@]}"; do
  if printf '%s\n' "${ACTIVE_MODELS[@]}" | grep -qxF -- "$m"; then
    AGY_MODELS+=("$m")
  fi
done
if [[ "${#AGY_MODELS[@]}" -eq 0 ]]; then
  AGY_MODELS=("${AGY_ALLOWED_MODELS[@]}")
fi

DEFAULT_MODEL_ID="gemini-3.8-flash"
FILTER_JSON=""
LIST_JSON=""
CSV_MODELS=""

for i in "${!AGY_MODELS[@]}"; do
  m="${AGY_MODELS[$i]}"
  dname="$(model_display_name "$m")"
  comma=","
  [[ "$i" -eq "$(( ${#AGY_MODELS[@]} - 1 ))" ]] && comma=""

  FILTER_JSON+="        \"${m}\"${comma}"$'\n'
  LIST_JSON+="        {
          \"modelId\": \"${m}\",
          \"displayName\": \"${dname}\",
          \"supportsThinking\": true
        }${comma}"$'\n'
  if [[ -z "$CSV_MODELS" ]]; then
    CSV_MODELS="$m"
  else
    CSV_MODELS="${CSV_MODELS},${m}"
  fi
done

cat > admin_settings.json <<EOF
{
  "gateway": {
    "enabled": true,
    "url": "${SERVICE_URL}",
    "apiKey": "${ACTIVE_API_KEY}",
    "wireProtocol": "genai",
    "customHeaders": {
      "X-Cost-Center": "Core-Engineering"
    },
    "models": {
      "defaultModelId": "${DEFAULT_MODEL_ID}",
      "filter": [
${FILTER_JSON%$'\n'}
      ],
      "list": [
${LIST_JSON%$'\n'}
      ]
    }
  },
  "models": {
    "defaultModelId": "${DEFAULT_MODEL_ID}",
    "filter": [
${FILTER_JSON%$'\n'}
    ],
    "list": [
${LIST_JSON%$'\n'}
    ]
  },
  "auth": {
    "suppressInteractiveLogin": true
  }
}
EOF

cat > gateway.env <<EOF
# Generated by ./deploy.sh for Antigravity CLI (agy)
# Normal setup:  ./setup-client.sh   (one time; makes this unnecessary to source)
# Manual/one-off use only:  source gateway.env   (affects the current shell only)
export AGY_LLM_GATEWAY_URL="${SERVICE_URL}"
export AGY_LLM_GATEWAY_API_KEY="${ACTIVE_API_KEY}"
export AGY_LLM_GATEWAY_HEADERS="X-Cost-Center: Core-Engineering"
export AGY_LLM_GATEWAY_MODELS="${CSV_MODELS}"
EOF

chmod 600 admin_settings.json gateway.env

# 8. Run Post-Deployment Verification Suite
echo -e "${GREEN}[8/8] Running post-deployment verification checks...${NC}"
chmod +x ./scripts/test_gateway.sh
LITELLM_MASTER_KEY="$ACTIVE_API_KEY" ./scripts/test_gateway.sh "$SERVICE_URL"

echo ""
echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${GREEN}${BOLD}   LiteLLM Proxy Deployment Complete & Verified!                      ${NC}"
echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${BOLD}Gateway URL:${NC}       ${SERVICE_URL}"
echo -e "${BOLD}API Docs:${NC}          ${SERVICE_URL}/  (Swagger UI)"
echo -e "${BOLD}API Key stored in:${NC} projects/${PROJECT_ID}/secrets/${SECRET_NAME}"
echo -e "${BOLD}Active Models (agy):${NC}     ${CSV_MODELS}"
if [[ "${#NOT_DEPLOYED_MODELS[@]}" -gt 0 ]]; then
  echo -e "${RED}${BOLD}Not Deployed Yet:${NC}  ${NOT_DEPLOYED_MODELS[*]} → run a full deploy: ${BOLD}./deploy.sh --project ${PROJECT_ID} --service ${SERVICE_NAME}${NC}"
fi
echo -e "${BOLD}Generated Files:${NC}   $(pwd)/admin_settings.json"
echo -e "                   $(pwd)/gateway.env"
echo ""
echo -e "${YELLOW}${BOLD}Step 1 — One-time client setup (Linux / macOS, run as your normal user, NOT with sudo):${NC}"
echo -e "  ./setup-client.sh"
echo -e "  It installs admin_settings.json system-wide (asks for sudo once) and makes every new terminal"
echo -e "  see the model list. You never need to run ${BOLD}source gateway.env${NC} again."
echo -e "  Another machine? Copy admin_settings.json + gateway.env + setup-client.sh there and run it."
echo -e "  Windows: see the PowerShell snippet in README.md."
echo ""
echo -e "${YELLOW}${BOLD}Step 2 — Verify your active model list & test inference (in a NEW terminal):${NC}"
echo -e "  agy models"
if [[ ",${CSV_MODELS}," == *",gemini-3.8-flash,"* ]]; then
  echo -e "  agy --model gemini-3.8-flash-low -p \"Explain how binary search works\""
elif [[ -n "${DEFAULT_MODEL_ID:-}" ]]; then
  echo -e "  agy --model ${DEFAULT_MODEL_ID} -p \"Explain how binary search works\""
fi
for m in "${AGY_MODELS[@]}"; do
  [[ "$m" == "$DEFAULT_MODEL_ID" ]] && continue
  echo -e "  agy --model ${m}-low -p \"Explain how binary search works\""
done
echo ""
echo -e "${YELLOW}${BOLD}Adding / removing models later${NC} (order: GCP side → gateway → re-run ./setup-client.sh on your machine):"
echo -e "  • Enabled a model in Model Garden that is ${BOLD}already listed${NC} in config.yaml?"
echo -e "    Run: ${BOLD}./deploy.sh --project ${PROJECT_ID} --service ${SERVICE_NAME} --sync-models${NC} (~5s, no container rebuild)"
echo -e "  • Enabled a model that is ${BOLD}not in${NC} config.yaml yet (e.g. a newly released Claude), or removed one?"
echo -e "    Edit config.yaml, then run: ${BOLD}./deploy.sh --project ${PROJECT_ID} --service ${SERVICE_NAME}${NC} (~3-5 min)"
echo -e "  • Either way, finish by re-running ${BOLD}./setup-client.sh${NC} (safe to repeat; also shortcut: add ${BOLD}--install-client${NC} to the deploy command)."
echo ""

if [[ "$INSTALL_CLIENT" == "true" ]]; then
  echo -e "${GREEN}Running one-time client setup on this machine (--install-client)...${NC}"
  if [[ "$(id -u)" -eq 0 ]]; then
    echo -e "${YELLOW}Skipped:${NC} deploy.sh is running as root; run ${BOLD}./setup-client.sh${NC} as your normal user instead."
  elif ! "${SCRIPT_DIR}/setup-client.sh"; then
    echo -e "${YELLOW}Client setup did not fully complete (deployment itself succeeded). Re-run: ${BOLD}./setup-client.sh${NC}"
  fi
fi

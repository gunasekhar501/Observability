#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  SecureOps — Local Stack Setup Script
#  Run ONCE after `docker compose up -d` to seed all services.
# ══════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Load .env ─────────────────────────────────────────────────
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  warn ".env not found — copying .env.example to .env"
  cp .env.example .env
  export $(grep -v '^#' .env | xargs)
fi

GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-SecureOps2026!}"
SONAR_PASS="${SONAR_ADMIN_PASSWORD:-admin}"

wait_for() {
  local name=$1 url=$2 max=${3:-60}
  info "Waiting for $name at $url ..."
  for i in $(seq 1 $max); do
    if curl -sf "$url" > /dev/null 2>&1; then
      success "$name is ready"
      return 0
    fi
    sleep 5
  done
  error "$name did not become ready in time."
}

# ─────────────────────────────────────────────────────────────
info "Step 1 — Checking host kernel settings for SonarQube"
# SonarQube requires vm.max_map_count >= 524288
CURRENT_MMC=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [ "$CURRENT_MMC" -lt 524288 ]; then
  warn "Setting vm.max_map_count=524288 (requires sudo)"
  sudo sysctl -w vm.max_map_count=524288
  sudo sysctl -w fs.file-max=131072
fi
success "Kernel settings OK"

# ─────────────────────────────────────────────────────────────
info "Step 2 — Starting core services"
docker compose up -d postgres minio
sleep 5

info "Step 3 — Starting all services"
docker compose up -d
info "Waiting 3 minutes for GitLab CE to initialise (this is normal)..."
sleep 180

# ─────────────────────────────────────────────────────────────
info "Step 4 — SonarQube setup"
wait_for "SonarQube" "http://localhost:9200/api/system/status" 40

# Change default admin password
curl -sf -X POST "http://localhost:9200/api/users/change_password" \
  -u "admin:admin" \
  -d "login=admin&previousPassword=admin&password=${SONAR_PASS}" && \
  success "SonarQube admin password set" || warn "SonarQube password already changed"

# Create project
curl -sf -X POST "http://localhost:9200/api/projects/create" \
  -u "admin:${SONAR_PASS}" \
  -d "name=java-secure-pipeline&project=java-secure-pipeline&visibility=private" && \
  success "SonarQube project created" || warn "SonarQube project may already exist"

# Generate user token and save to .env
SONAR_TOKEN_JSON=$(curl -sf -X POST "http://localhost:9200/api/user_tokens/generate" \
  -u "admin:${SONAR_PASS}" \
  -d "name=secureops-ci&type=GLOBAL_ANALYSIS_TOKEN")
SONAR_TOKEN_VAL=$(echo "$SONAR_TOKEN_JSON" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -n "$SONAR_TOKEN_VAL" ]; then
  sed -i.bak "s/^SONAR_TOKEN=.*/SONAR_TOKEN=${SONAR_TOKEN_VAL}/" .env
  success "SonarQube token saved to .env: ${SONAR_TOKEN_VAL:0:8}..."
fi

# Configure webhook to SecureOps API
curl -sf -X POST "http://localhost:9200/api/webhooks/create" \
  -u "admin:${SONAR_PASS}" \
  -d "name=secureops&url=http://secureops-api:8080/api/webhook/sonar&project=java-secure-pipeline" && \
  success "SonarQube webhook configured" || warn "SonarQube webhook may already exist"

# ─────────────────────────────────────────────────────────────
info "Step 5 — GitLab CE setup"
wait_for "GitLab" "http://localhost:8929/-/health" 60

# Create SecureOps group
GITLAB_TOKEN_RESP=$(curl -sf "http://localhost:8929/api/v4/users/1/personal_access_tokens" \
  -H "PRIVATE-TOKEN: $(docker exec secureops-gitlab gitlab-rails runner \
    "puts User.find(1).personal_access_tokens.create(name:'setup', scopes:[:api], expires_at: 30.days.from_now).token" \
    2>/dev/null)" 2>/dev/null || echo "{}")

# Create group
curl -sf -X POST "http://localhost:8929/api/v4/groups" \
  -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN:-}" \
  -d "name=platform&path=platform&visibility=internal" && \
  success "GitLab group 'platform' created" || warn "GitLab group may already exist"

# Register GitLab runner
if [ -n "${GITLAB_RUNNER_TOKEN:-}" ]; then
  docker exec secureops-gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "http://gitlab:8929" \
    --registration-token "${GITLAB_RUNNER_TOKEN}" \
    --executor "docker" \
    --docker-image "eclipse-temurin:17-jdk-alpine" \
    --docker-network-mode "secureops-net" \
    --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
    --description "secureops-runner" \
    --tag-list "docker,java,secureops" && \
    success "GitLab runner registered" || warn "Runner registration failed — set GITLAB_RUNNER_TOKEN in .env"
else
  warn "GITLAB_RUNNER_TOKEN not set — register the runner manually after first GitLab login."
fi

# Configure GitLab webhook to SecureOps API
if [ -n "${GITLAB_API_TOKEN:-}" ]; then
  # Get project ID (assumes project was pushed already)
  PROJECT_ID=$(curl -sf "http://localhost:8929/api/v4/projects?search=java-secure-pipeline" \
    -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

  if [ -n "$PROJECT_ID" ]; then
    curl -sf -X POST "http://localhost:8929/api/v4/projects/${PROJECT_ID}/hooks" \
      -H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"url":"http://secureops-api:8080/api/webhook/gitlab","pipeline_events":true,"job_events":true}' && \
      success "GitLab pipeline webhook configured" || warn "GitLab webhook setup failed"
  fi
fi

# ─────────────────────────────────────────────────────────────
info "Step 6 — Mattermost channel setup"
wait_for "Mattermost" "http://localhost:8065/api/v4/system/ping" 30

# Create admin user via CLI (first boot only)
docker exec secureops-mattermost mattermost user create \
  --email "${PLANE_ADMIN_EMAIL:-admin@secureops.local}" \
  --username "secureops-admin" \
  --password "${PLANE_ADMIN_PASSWORD:-SecureOps2026!}" \
  --system_admin 2>/dev/null && success "Mattermost admin created" || warn "Mattermost admin may already exist"

# Create team and channel
docker exec secureops-mattermost mattermost team create \
  --name "secureops" --display_name "SecureOps" --email "${PLANE_ADMIN_EMAIL:-admin@secureops.local}" \
  2>/dev/null && success "Mattermost team created" || warn "Mattermost team may already exist"

docker exec secureops-mattermost mattermost channel create \
  --team "secureops" --name "platform-alerts" --display_name "Platform Alerts" \
  2>/dev/null && success "Mattermost #platform-alerts created" || warn "Channel may already exist"

# ─────────────────────────────────────────────────────────────
info "Step 7 — Wiki.js RCA space setup"
wait_for "Wiki.js" "http://localhost:3000/healthz" 20
success "Wiki.js is running — complete setup at http://localhost:3000"
success "Create an API token at: Administration → API Access → Add Token"
warn  "Paste the token as WIKIJS_API_TOKEN in .env then restart: docker compose restart secureops-api"

# ─────────────────────────────────────────────────────────────
info "Step 8 — Plane workspace setup"
wait_for "Plane API" "http://localhost:8000/api/health/" 30
success "Plane is running at http://localhost:3001"
success "Log in with: ${PLANE_ADMIN_EMAIL:-admin@secureops.local} / ${PLANE_ADMIN_PASSWORD:-SecureOps2026!}"
warn  "After login: create a workspace '${PLANE_WORKSPACE:-secureops}' and a project 'SEC'"
warn  "Paste the project ID as PLANE_PROJECT_ID in .env and generate an API token as PLANE_API_TOKEN"
warn  "Then restart: docker compose restart secureops-api"

# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SecureOps Local Stack is UP!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  Service              URL"
echo "  ──────────────────   ──────────────────────────────"
echo "  Dashboard            http://localhost:8081"
echo "  SecureOps API        http://localhost:8080/docs"
echo "  GitLab CE            http://localhost:8929   (root / ${GITLAB_ROOT_PASSWORD})"
echo "  SonarQube            http://localhost:9200   (admin / ${SONAR_PASS})"
echo "  Plane (Jira)         http://localhost:3001"
echo "  Wiki.js (Confluence) http://localhost:3000"
echo "  Mattermost (Slack)   http://localhost:8065"
echo "  MinIO Console        http://localhost:9001"
echo ""
echo "  Run './scripts/healthcheck.sh' to verify all services."
echo ""

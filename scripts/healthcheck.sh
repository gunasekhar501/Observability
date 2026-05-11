#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  SecureOps — Stack Health Check
# ══════════════════════════════════════════════════════════════
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC}  $1"; }
fail() { echo -e "  ${RED}✗${NC}  $1"; FAILED=$((FAILED+1)); }
warn() { echo -e "  ${YELLOW}~${NC}  $1"; }

FAILED=0

check() {
  local name=$1 url=$2 pattern=${3:-}
  local resp
  resp=$(curl -sf --max-time 5 "$url" 2>/dev/null)
  if [ $? -ne 0 ]; then
    fail "$name  ($url)"
  elif [ -n "$pattern" ] && ! echo "$resp" | grep -q "$pattern"; then
    warn "$name — up but pattern '$pattern' not found"
  else
    pass "$name"
  fi
}

echo ""
echo "SecureOps Stack Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "────────────────────────────────────────────────────────"

check "SecureOps Dashboard"    "http://localhost:8081/healthz"            "ok"
check "SecureOps API"          "http://localhost:8080/health"             "ok"
check "GitLab CE"              "http://localhost:8929/-/health"           "GitLab OK"
check "GitLab Registry"        "http://localhost:5050/v2/"
check "SonarQube"              "http://localhost:9200/api/system/status"  "UP"
check "Wiki.js"                "http://localhost:3000/healthz"
check "Plane API"              "http://localhost:8000/api/health/"
check "Plane Web"              "http://localhost:3001"
check "Mattermost"             "http://localhost:8065/api/v4/system/ping" "OK"
check "MinIO S3 API"           "http://localhost:9000/minio/health/live"
check "MinIO Console"          "http://localhost:9001"
check "PostgreSQL"             # checked via docker
docker exec secureops-postgres pg_isready -U secureops > /dev/null 2>&1 && pass "PostgreSQL" || fail "PostgreSQL"

echo "────────────────────────────────────────────────────────"
echo ""

# Container status
echo "Container Status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
  docker ps --filter "name=secureops" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo -e "${GREEN}All services healthy.${NC}"
else
  echo -e "${RED}$FAILED service(s) unhealthy — check 'docker compose logs <service>'.${NC}"
  exit 1
fi

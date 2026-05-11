#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  SecureOps — Deployment Proof Collector
#  Captures all CLI evidence of a successful AWS deployment and
#  writes it to docs/proof/<timestamp>/
#
#  Run AFTER deploy-aws.sh completes:
#    ./scripts/generate-proof.sh
# ══════════════════════════════════════════════════════════════════
set -uo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CLUSTER="secureops-eks"
NAMESPACE="secureops"
TS=$(date '+%Y%m%d_%H%M%S')
PROOF_DIR="docs/proof/${TS}"
TF_DIR="terraform/environments/aws"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${BLUE}[PROOF]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC}  $* (not available)"; }

mkdir -p "$PROOF_DIR"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")

echo ""
echo "SecureOps Deployment Proof — $(date '+%Y-%m-%d %H:%M:%S')"
echo "Account: ${ACCOUNT_ID}  Region: ${REGION}"
echo "Output: ${PROOF_DIR}/"
echo "────────────────────────────────────────────────────────"

# ── 1. AWS Identity ───────────────────────────────────────────────
info "1. AWS caller identity..."
aws sts get-caller-identity --output json > "${PROOF_DIR}/01_aws_identity.json" 2>/dev/null \
  && success "01_aws_identity.json" || warn "AWS identity"

# ── 2. Terraform outputs ──────────────────────────────────────────
info "2. Terraform outputs..."
if [ -d "$TF_DIR" ]; then
  (cd "$TF_DIR" && terraform output -json) > "${PROOF_DIR}/02_terraform_outputs.json" 2>/dev/null \
    && success "02_terraform_outputs.json" || warn "Terraform outputs"
fi

# ── 3. VPC ────────────────────────────────────────────────────────
info "3. VPC and subnets..."
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=java-secure-pipeline" \
  --region "$REGION" --output json \
  > "${PROOF_DIR}/03_vpc.json" 2>/dev/null && success "03_vpc.json" || warn "VPC"

aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=java-secure-pipeline" \
  --region "$REGION" --output json \
  > "${PROOF_DIR}/03_subnets.json" 2>/dev/null && success "03_subnets.json" || warn "Subnets"

# ── 4. EKS Cluster ────────────────────────────────────────────────
info "4. EKS cluster..."
aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --output json \
  > "${PROOF_DIR}/04_eks_cluster.json" 2>/dev/null && success "04_eks_cluster.json" || warn "EKS cluster"

aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --output json \
  > "${PROOF_DIR}/04_eks_nodegroups.json" 2>/dev/null && success "04_eks_nodegroups.json" || warn "EKS nodegroups"

# ── 5. kubectl — nodes ────────────────────────────────────────────
info "5. Kubernetes nodes..."
kubectl get nodes -o wide 2>/dev/null \
  > "${PROOF_DIR}/05_kubectl_nodes.txt" && success "05_kubectl_nodes.txt" || warn "kubectl nodes"

kubectl get nodes -o json 2>/dev/null \
  > "${PROOF_DIR}/05_kubectl_nodes.json" && true || true

# ── 6. kubectl — all workloads ────────────────────────────────────
info "6. Kubernetes workloads (${NAMESPACE} namespace)..."
kubectl get all -n "$NAMESPACE" -o wide 2>/dev/null \
  > "${PROOF_DIR}/06_kubectl_all.txt" && success "06_kubectl_all.txt" || warn "kubectl get all"

kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null \
  > "${PROOF_DIR}/06_kubectl_pods.json" && true || true

# ── 7. kubectl — ingress / ALB URL ───────────────────────────────
info "7. Ingress and ALB..."
kubectl get ingress -n "$NAMESPACE" -o wide 2>/dev/null \
  > "${PROOF_DIR}/07_kubectl_ingress.txt" && success "07_kubectl_ingress.txt" || warn "kubectl ingress"

ALB_URL=$(kubectl get ingress secureops-ingress -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

# ── 8. ECR repositories ───────────────────────────────────────────
info "8. ECR repositories..."
aws ecr describe-repositories \
  --region "$REGION" --output json \
  > "${PROOF_DIR}/08_ecr_repos.json" 2>/dev/null && success "08_ecr_repos.json" || warn "ECR repos"

# ECR image tags for each repo
for REPO in java-secure-pipeline secureops-api secureops-dashboard; do
  aws ecr list-images --repository-name "$REPO" --region "$REGION" --output json \
    > "${PROOF_DIR}/08_ecr_images_${REPO}.json" 2>/dev/null || true
done
success "08_ecr_images_*.json"

# ── 9. RDS ────────────────────────────────────────────────────────
info "9. RDS instance..."
aws rds describe-db-instances \
  --filters "Name=db-instance-id,Values=secureops-postgres" \
  --region "$REGION" --output json \
  > "${PROOF_DIR}/09_rds.json" 2>/dev/null && success "09_rds.json" || warn "RDS"

# ── 10. S3 buckets ────────────────────────────────────────────────
info "10. S3 buckets..."
aws s3 ls 2>/dev/null | grep secureops \
  > "${PROOF_DIR}/10_s3_buckets.txt" && success "10_s3_buckets.txt" || warn "S3 buckets"

aws s3 ls "s3://secureops-pipeline-reports-${ACCOUNT_ID}/" 2>/dev/null \
  > "${PROOF_DIR}/10_s3_reports_contents.txt" || true

# ── 11. Secrets Manager ───────────────────────────────────────────
info "11. Secrets Manager (keys only — no values)..."
aws secretsmanager list-secrets \
  --filters Key=name,Values=/secureops \
  --region "$REGION" --output json \
  > "${PROOF_DIR}/11_secrets.json" 2>/dev/null && success "11_secrets.json" || warn "Secrets Manager"

# ── 12. Health endpoint checks ────────────────────────────────────
info "12. Health checks..."
{
  echo "Health Check Report — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "ALB: ${ALB_URL:-NOT_AVAILABLE}"
  echo "────────────────────────────────────────────────────────"
} > "${PROOF_DIR}/12_health_checks.txt"

check_endpoint() {
  local name=$1 url=$2
  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "FAIL")
  echo "  [${status}] ${name}: ${url}" | tee -a "${PROOF_DIR}/12_health_checks.txt"
}

if [ -n "$ALB_URL" ]; then
  check_endpoint "Dashboard"      "http://${ALB_URL}/"
  check_endpoint "Dashboard /healthz" "http://${ALB_URL}/healthz"
  check_endpoint "API /health"    "http://${ALB_URL}/api/health"
  check_endpoint "API /docs"      "http://${ALB_URL}/api/docs"
  check_endpoint "Java App /api/users/count" "http://${ALB_URL}/app/api/users/count"
else
  echo "  ALB URL not available yet — run after ingress is provisioned" \
    >> "${PROOF_DIR}/12_health_checks.txt"
  warn "Health checks (ALB not provisioned yet)"
fi
success "12_health_checks.txt"

# ── 13. SecureOps API — findings summary ─────────────────────────
info "13. SecureOps API findings..."
if [ -n "$ALB_URL" ]; then
  curl -sf "http://${ALB_URL}/api/dashboard/summary" 2>/dev/null \
    | python3 -m json.tool > "${PROOF_DIR}/13_api_findings_summary.json" 2>/dev/null \
    && success "13_api_findings_summary.json" || warn "API summary"

  curl -sf "http://${ALB_URL}/api/findings?limit=50" 2>/dev/null \
    | python3 -m json.tool > "${PROOF_DIR}/13_api_findings_list.json" 2>/dev/null \
    && success "13_api_findings_list.json" || warn "API findings list"
fi

# ── 14. SpotBugs scan report (if present) ────────────────────────
info "14. Security scan artifacts..."
if [ -f "target/spotbugsXml.xml" ]; then
  cp target/spotbugsXml.xml "${PROOF_DIR}/14_spotbugs_report.xml"
  SPOTBUGS_COUNT=$(grep -c '<BugInstance' target/spotbugsXml.xml 2>/dev/null || echo 0)
  success "14_spotbugs_report.xml (${SPOTBUGS_COUNT} findings)"
fi

if [ -f "target/dependency-check/dependency-check-report.json" ]; then
  cp target/dependency-check/dependency-check-report.json "${PROOF_DIR}/14_owasp_report.json"
  CVE_COUNT=$(python3 -c \
    "import json; r=json.load(open('target/dependency-check/dependency-check-report.json')); \
     print(sum(len(d.get('vulnerabilities',[])) for d in r.get('dependencies',[])))" 2>/dev/null || echo "?")
  success "14_owasp_report.json (${CVE_COUNT} CVEs)"
fi

# ── 15. Generate proof index JSON ─────────────────────────────────
info "15. Writing proof index..."
cat > "${PROOF_DIR}/00_index.json" << INDEXEOF
{
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "account_id": "${ACCOUNT_ID}",
  "region": "${REGION}",
  "cluster": "${CLUSTER}",
  "alb_url": "${ALB_URL:-pending}",
  "files": $(ls "${PROOF_DIR}/" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().split()))")
}
INDEXEOF
success "00_index.json"

echo ""
echo "────────────────────────────────────────────────────────"
echo -e "${GREEN}Proof collected → ${PROOF_DIR}/${NC}"
echo ""
echo "Files captured:"
ls -1 "${PROOF_DIR}/" | sed 's/^/  /'
echo ""
echo "Next: open docs/implementation-guide.html in your browser"
echo "      and paste the ALB URL screenshots into the doc."
echo ""

# Export path for documentation generator
export PROOF_DIR ALB_URL ACCOUNT_ID REGION TS

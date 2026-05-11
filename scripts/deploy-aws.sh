#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  SecureOps — AWS Full Deployment Script
#  Bootstraps Terraform state, provisions all infrastructure,
#  builds Docker images, and deploys to EKS.
#
#  Prerequisites (must be installed):
#    aws-cli v2, terraform >= 1.7, kubectl, helm, docker, maven
#
#  Usage:
#    export AWS_ACCESS_KEY_ID=AKIAxxxxxxxxxxxxxxxx
#    export AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#    export AWS_DEFAULT_REGION=ap-south-1
#    chmod +x scripts/deploy-aws.sh
#    ./scripts/deploy-aws.sh
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CLUSTER_NAME="secureops-eks"
NAMESPACE="secureops"
TF_DIR="terraform/environments/aws"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[AWS]${NC}   $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo ""; echo -e "${BLUE}══ Step $* ══════════════════════════════════════${NC}"; }

# ── Validate credentials ──────────────────────────────────────────
step "0 — Validating AWS credentials"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || error "AWS credentials not set or invalid. Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
success "Account: ${ACCOUNT_ID}  Region: ${REGION}"

# ── Bootstrap Terraform state bucket + DynamoDB ───────────────────
step "1 — Bootstrapping Terraform remote state"
TF_BUCKET="secureops-tf-state-${ACCOUNT_ID}"
TF_TABLE="secureops-tf-lock"

if ! aws s3api head-bucket --bucket "$TF_BUCKET" 2>/dev/null; then
  info "Creating S3 state bucket: $TF_BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TF_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$TF_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$TF_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$TF_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$TF_BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  success "State bucket created: $TF_BUCKET"
else
  success "State bucket already exists: $TF_BUCKET"
fi

# Enable S3 object lock for state locking (replaces DynamoDB — no extra resource needed)
aws s3api put-bucket-versioning --bucket "$TF_BUCKET" \
  --versioning-configuration Status=Enabled 2>/dev/null || true

# Detect actual bucket region (in case bucket already existed in a different region)
TF_BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_BUCKET" \
  --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
# us-east-1 returns "None" from get-bucket-location
[ "$TF_BUCKET_REGION" = "None" ] && TF_BUCKET_REGION="us-east-1"
info "State bucket region: ${TF_BUCKET_REGION}"

# Patch backend bucket name and region into Terraform config
sed -i.bak "s/secureops-tf-state-ACCOUNT_ID/${TF_BUCKET}/" "$TF_DIR/main.tf"
sed -i "s|region       = \"us-east-1\"|region       = \"${TF_BUCKET_REGION}\"|" "$TF_DIR/main.tf"

# ── Terraform init, plan, apply ───────────────────────────────────
step "2 — Terraform init"
cd "$TF_DIR"
terraform init \
  -backend-config="bucket=${TF_BUCKET}" \
  -backend-config="region=${TF_BUCKET_REGION}" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"

step "3 — Terraform plan"
terraform plan -out=tfplan \
  -var="region=${REGION}"
echo ""
warn "Review the plan above. Press ENTER to apply or Ctrl-C to abort."
read -r

step "4 — Terraform apply (this takes ~15 minutes for EKS)"
terraform apply tfplan
success "Infrastructure provisioned!"

# ── Capture outputs ───────────────────────────────────────────────
ECR_JAVA=$(terraform output -raw ecr_repo_urls 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('java-secure-pipeline',''))" || echo "")
ECR_API=$(terraform output -raw ecr_repo_urls 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('secureops-api',''))" || echo "")
ECR_DASH=$(terraform output -raw ecr_repo_urls 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('secureops-dashboard',''))" || echo "")

cd - > /dev/null

# ── Update kubeconfig ─────────────────────────────────────────────
step "5 — Configuring kubectl"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl cluster-info
success "kubectl configured"

# ── Build and push Docker images ──────────────────────────────────
step "6 — Building and pushing Docker images to ECR"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Java app
info "Building java-secure-pipeline..."
mvn --batch-mode --no-transfer-progress package -DskipTests -q
docker build -t "${ECR_JAVA}:latest" .
docker push "${ECR_JAVA}:latest"
success "java-secure-pipeline pushed"

# SecureOps API
info "Building secureops-api..."
docker build -t "${ECR_API}:latest" secureops-api/
docker push "${ECR_API}:latest"
success "secureops-api pushed"

# Dashboard
info "Building dashboard..."
docker build -t "${ECR_DASH}:latest" -f nginx/Dockerfile nginx/
docker push "${ECR_DASH}:latest"
success "dashboard pushed"

# ── Create K8s namespace and secrets ─────────────────────────────
step "7 — Creating Kubernetes namespace and secrets"
kubectl apply -f k8s/namespace.yaml

# Pull secrets from Secrets Manager
APP_SECRETS=$(aws secretsmanager get-secret-value \
  --secret-id "/secureops/app-secrets" \
  --region "$REGION" \
  --query SecretString --output text)

DB_HOST=$(echo "$APP_SECRETS" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['db_host'])")
DB_PORT=$(echo "$APP_SECRETS" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['db_port'])")
DB_NAME=$(echo "$APP_SECRETS" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['db_name'])")
DB_PASS=$(echo "$APP_SECRETS" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['db_password'])")
API_KEY=$(echo "$APP_SECRETS" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['api_secret_key'])")

kubectl create secret generic secureops-secrets \
  --namespace "$NAMESPACE" \
  --from-literal=database_url="postgresql://secureops:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}" \
  --from-literal=api_secret_key="${API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

success "Secrets created in Kubernetes"

# ── Patch image URLs into K8s manifests ───────────────────────────
step "8 — Patching image URLs and deploying to EKS"
sed "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/secureops-api:latest|${ECR_API}:latest|g" \
  k8s/secureops-api.yaml | kubectl apply -f -

sed "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/secureops-dashboard:latest|${ECR_DASH}:latest|g" \
  k8s/dashboard.yaml | kubectl apply -f -

sed "s|ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/java-secure-pipeline:latest|${ECR_JAVA}:latest|g" \
  k8s/java-app.yaml | kubectl apply -f -

# ── Install AWS Load Balancer Controller (for ALB ingress) ─────────
step "9 — Installing AWS Load Balancer Controller"
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=true \
  --set region="$REGION" \
  --set vpcId="$(aws eks describe-cluster --name "$CLUSTER_NAME" \
    --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)" \
  --wait --timeout=5m

# Apply ingress (ALB)
kubectl apply -f k8s/ingress.yaml

# ── Wait for pods and get ALB URL ─────────────────────────────────
step "10 — Waiting for deployments to be ready"
kubectl rollout status deployment/secureops-api -n "$NAMESPACE" --timeout=3m
kubectl rollout status deployment/dashboard -n "$NAMESPACE" --timeout=3m

info "Waiting for ALB to be provisioned (up to 3 minutes)..."
for i in $(seq 1 18); do
  ALB_URL=$(kubectl get ingress secureops-ingress -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$ALB_URL" ]; then
    break
  fi
  sleep 10
done

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SecureOps is deployed on AWS EKS!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  Dashboard:       http://${ALB_URL}"
echo "  API docs:        http://${ALB_URL}/api/docs"
echo "  Java app:        http://${ALB_URL}/app/api/users"
echo ""
echo "  ECR Java app:    ${ECR_JAVA}"
echo "  ECR API:         ${ECR_API}"
echo "  ECR Dashboard:   ${ECR_DASH}"
echo ""
echo "  Run security scans:"
echo "    SECUREOPS_API_URL=http://${ALB_URL} ./scripts/run-local-scan.sh"
echo ""
echo -e "${YELLOW}  Cost reminder: EKS + 2x t3.medium + RDS + NAT ≈ \$195/month${NC}"
echo -e "${YELLOW}  To destroy: cd ${TF_DIR} && terraform destroy${NC}"
echo ""

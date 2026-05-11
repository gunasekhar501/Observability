#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  SecureOps — GitHub Repository Setup & Push
#  Creates 6 repos under gunasekhar501 and pushes organised content
#
#  Prerequisites:
#    gh auth login   (GitHub CLI authenticated)
#    git config --global user.name / user.email set
#
#  Run from project root:
#    chmod +x scripts/push-to-github.sh
#    ./scripts/push-to-github.sh
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

GITHUB_USER="gunasekhar501"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="/tmp/secureops-github-push"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${BLUE}[PUSH]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }

rm -rf "$TMP_BASE"
mkdir -p "$TMP_BASE"

# ── Helper: create repo if it doesn't exist, then push ────────────
push_repo() {
  local repo_name="$1"
  local src_dir="$2"
  local description="$3"

  info "Processing ${repo_name}..."

  local work_dir="${TMP_BASE}/${repo_name}"
  cp -r "$src_dir" "$work_dir"

  cd "$work_dir"
  git init -q
  git checkout -b main
  git add .
  git commit -q -m "Initial commit — SecureOps ${repo_name}"

  # Create repo on GitHub (skip if already exists)
  gh repo create "${GITHUB_USER}/${repo_name}" \
    --public \
    --description "$description" \
    --source=. \
    --remote=origin \
    --push 2>/dev/null || {
    # Repo exists — just force push
    git remote add origin "https://github.com/${GITHUB_USER}/${repo_name}.git" 2>/dev/null || true
    git push -u origin main --force
  }

  success "${repo_name} → https://github.com/${GITHUB_USER}/${repo_name}"
  cd "$PROJECT_ROOT"
}

# ══════════════════════════════════════════════════════════════════
# 1. TERRAFORM
# ══════════════════════════════════════════════════════════════════
info "Preparing Terraform repo..."
TERRAFORM_DIR="${TMP_BASE}/terraform-src"
mkdir -p "$TERRAFORM_DIR"
cp -r "${PROJECT_ROOT}/terraform/modules"      "$TERRAFORM_DIR/"
cp -r "${PROJECT_ROOT}/terraform/environments" "$TERRAFORM_DIR/"
cp -r "${PROJECT_ROOT}/terraform/backends"     "$TERRAFORM_DIR/" 2>/dev/null || true

cat > "${TERRAFORM_DIR}/.gitignore" << 'EOF'
.terraform/
*.tfstate
*.tfstate.backup
*.tfplan
tfplan
.terraform.lock.hcl
*.bak
override.tf
override.tf.json
EOF

cat > "${TERRAFORM_DIR}/README.md" << 'EOF'
# SecureOps — Terraform

Reusable Terraform modules and environment configurations for AWS infrastructure.

## Modules
| Module | Description |
|--------|-------------|
| `modules/vpc` | VPC, subnets, IGW, NAT Gateway, route tables |
| `modules/eks` | EKS 1.31, managed node group, OIDC, addons |
| `modules/rds` | PostgreSQL 16 RDS in private subnet |
| `modules/ecr` | ECR repositories with lifecycle policies |
| `modules/s3` | Pipeline reports bucket |
| `modules/iam` | IAM roles and policies |

## Environments
| Environment | Description |
|-------------|-------------|
| `environments/aws` | Production AWS (us-east-1) |
| `environments/dev` | Development |
| `environments/staging` | Staging |

## Usage
```bash
cd environments/aws
terraform init
terraform plan -var="region=us-east-1"
terraform apply -var="region=us-east-1"
```
EOF

push_repo "Terraform" "$TERRAFORM_DIR" "SecureOps Terraform modules — VPC, EKS, RDS, ECR, S3"

# ══════════════════════════════════════════════════════════════════
# 2. KUBERNETES
# ══════════════════════════════════════════════════════════════════
info "Preparing Kubernetes repo..."
KUBERNETES_DIR="${TMP_BASE}/kubernetes-src"
mkdir -p "$KUBERNETES_DIR"
cp -r "${PROJECT_ROOT}/k8s" "${KUBERNETES_DIR}/manifests"

cat > "${KUBERNETES_DIR}/README.md" << 'EOF'
# SecureOps — Kubernetes Manifests

Raw Kubernetes manifests for the SecureOps platform on EKS.

## Manifests
| File | Description |
|------|-------------|
| `manifests/namespace.yaml` | secureops namespace |
| `manifests/secureops-api.yaml` | FastAPI backend deployment + service |
| `manifests/dashboard.yaml` | nginx dashboard deployment + service |
| `manifests/java-app.yaml` | Java Spring Boot deployment + service |
| `manifests/ingress.yaml` | ALB ingress — routes /, /api, /app |

## Apply
```bash
aws eks update-kubeconfig --region us-east-1 --name secureops-eks
kubectl apply -f manifests/
```
EOF

cat > "${KUBERNETES_DIR}/.gitignore" << 'EOF'
*.secret.yaml
*-secret.yaml
EOF

push_repo "Kubernetes" "$KUBERNETES_DIR" "SecureOps Kubernetes manifests — EKS deployments, services, ALB ingress"

# ══════════════════════════════════════════════════════════════════
# 3. HELM
# ══════════════════════════════════════════════════════════════════
info "Preparing Helm repo..."
HELM_DIR="${TMP_BASE}/helm-src"
mkdir -p "$HELM_DIR"
cp -r "${PROJECT_ROOT}/helm" "${HELM_DIR}/"

cat > "${HELM_DIR}/README.md" << 'EOF'
# SecureOps — Helm Charts

Helm chart for the Java secure pipeline application with multi-environment value overrides.

## Chart: java-secure-pipeline
```
helm/java-secure-pipeline/
├── Chart.yaml
├── values.yaml          # defaults
├── values-dev.yaml      # dev overrides
├── values-staging.yaml  # staging overrides
└── values-prod.yaml     # production overrides
    templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── configmap.yaml
    ├── hpa.yaml
    ├── networkpolicy.yaml
    ├── poddisruptionbudget.yaml
    └── serviceaccount.yaml
```

## Install
```bash
# Dev
helm upgrade --install java-app helm/java-secure-pipeline \
  -f helm/java-secure-pipeline/values-dev.yaml \
  --namespace secureops --create-namespace

# Production
helm upgrade --install java-app helm/java-secure-pipeline \
  -f helm/java-secure-pipeline/values-prod.yaml \
  --namespace secureops
```
EOF

push_repo "Helm" "$HELM_DIR" "SecureOps Helm charts — Java app with dev/staging/prod value overrides"

# ══════════════════════════════════════════════════════════════════
# 4. ARGOCD (GitOps)
# ══════════════════════════════════════════════════════════════════
info "Preparing ArgoCD repo..."
ARGOCD_DIR="${TMP_BASE}/argocd-src"
mkdir -p "$ARGOCD_DIR"
cp -r "${PROJECT_ROOT}/argocd" "${ARGOCD_DIR}/"

cat > "${ARGOCD_DIR}/README.md" << 'EOF'
# SecureOps — ArgoCD GitOps

ArgoCD application manifests for GitOps continuous delivery.

## Structure
```
argocd/
├── appproject.yaml        # SecureOps AppProject
├── application-dev.yaml   # Dev environment sync
├── application-staging.yaml
└── application-prod.yaml  # Production sync
```

## Setup
```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Apply project and applications
kubectl apply -f argocd/appproject.yaml
kubectl apply -f argocd/application-dev.yaml
kubectl apply -f argocd/application-prod.yaml

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Flow
Git push → ArgoCD detects diff → auto-sync → kubectl apply → EKS updated
EOF

push_repo "ArgoCD" "$ARGOCD_DIR" "SecureOps ArgoCD GitOps — application manifests for dev/staging/prod"

# ══════════════════════════════════════════════════════════════════
# 5. AWS-CLOUD (App code + CI/CD + scripts)
# ══════════════════════════════════════════════════════════════════
info "Preparing AWS-Cloud repo..."
AWSCLOUD_DIR="${TMP_BASE}/awscloud-src"
mkdir -p "$AWSCLOUD_DIR"

# Copy app source
cp -r "${PROJECT_ROOT}/src"            "$AWSCLOUD_DIR/"
cp -r "${PROJECT_ROOT}/secureops-api"  "$AWSCLOUD_DIR/"
cp -r "${PROJECT_ROOT}/nginx"          "$AWSCLOUD_DIR/"
cp -r "${PROJECT_ROOT}/config"         "$AWSCLOUD_DIR/"
cp -r "${PROJECT_ROOT}/scripts"        "$AWSCLOUD_DIR/"
cp    "${PROJECT_ROOT}/pom.xml"        "$AWSCLOUD_DIR/"
cp    "${PROJECT_ROOT}/Dockerfile"     "$AWSCLOUD_DIR/"
cp    "${PROJECT_ROOT}/docker-compose.yml" "$AWSCLOUD_DIR/"
cp    "${PROJECT_ROOT}/.env.example"   "$AWSCLOUD_DIR/"
cp    "${PROJECT_ROOT}/.gitlab-ci.yml" "$AWSCLOUD_DIR/"
cp    "${PROJECT_ROOT}/sonar-project.properties" "$AWSCLOUD_DIR/" 2>/dev/null || true
mkdir -p "${AWSCLOUD_DIR}/.github/workflows"
cp -r "${PROJECT_ROOT}/.github/workflows/." "${AWSCLOUD_DIR}/.github/workflows/" 2>/dev/null || true

cat > "${AWSCLOUD_DIR}/.gitignore" << 'EOF'
target/
*.class
*.jar
*.war
.env
*.secret
__pycache__/
*.pyc
.venv/
node_modules/
EOF

cat > "${AWSCLOUD_DIR}/README.md" << 'EOF'
# SecureOps — AWS Cloud / Application

Java Spring Boot application with intentional security vulnerabilities, FastAPI backend,
nginx dashboard, CI/CD pipelines, and deployment scripts.

## Structure
```
├── src/                    Java Spring Boot application
├── secureops-api/          FastAPI findings backend
├── nginx/                  Dashboard nginx container
├── config/                 SpotBugs, PMD, Checkstyle, OWASP config
├── scripts/
│   ├── deploy-aws.sh       Full AWS deployment (EKS + ECR + K8s)
│   ├── run-local-scan.sh   Maven security scans → push to API
│   ├── generate-proof.sh   Collect deployment evidence
│   └── setup-wsl.sh        Install tools in WSL Ubuntu
├── .github/workflows/      GitHub Actions CI pipelines
├── .gitlab-ci.yml          GitLab CI pipeline
├── docker-compose.yml      Full local stack
└── pom.xml                 Maven build + security plugins
```

## Quick Start (AWS)
```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
./scripts/deploy-aws.sh
```

## Security Findings (Intentional)
| Vulnerability | Class | Scanner |
|--------------|-------|---------|
| MD5/SHA1 hashing | CryptoUtils.java | SpotBugs |
| SQL injection | SqlQueryBuilder.java | SpotBugs |
| Hardcoded password | SqlQueryBuilder, AuthController | SpotBugs |
| Path traversal | ReportController.java | SpotBugs |
| CVE-2017-15708 (CVSS 9.8) | commons-collections:3.2.1 | OWASP |
EOF

push_repo "AWS-Cloud" "$AWSCLOUD_DIR" "SecureOps app code, CI/CD pipelines, deployment scripts for AWS EKS"

# ══════════════════════════════════════════════════════════════════
# 6. DOCUMENTS
# ══════════════════════════════════════════════════════════════════
info "Preparing Documents repo..."
DOCS_DIR="${TMP_BASE}/docs-src"
mkdir -p "$DOCS_DIR"
cp -r "${PROJECT_ROOT}/docs/." "$DOCS_DIR/" 2>/dev/null || true
cp    "${PROJECT_ROOT}/SecureOps-Platform-Overview.pptx" "$DOCS_DIR/" 2>/dev/null || true

cat > "${DOCS_DIR}/README.md" << 'EOF'
# SecureOps — Project Documentation

All project documentation, implementation guides, and proof artifacts.

## Documents
| File | Description |
|------|-------------|
| `implementation-guide.html` | Step-by-step deployment guide with screenshot slots |
| `project-scope.md` | Objectives, deliverables, timeline, stakeholders |
| `benefits-and-cons.md` | Benefits analysis and known limitations |
| `SecureOps-Platform-Overview.pptx` | Executive overview presentation |
| `proof/<timestamp>/` | CLI evidence from generate-proof.sh |

## Architecture
```
┌─────────────────────────────────────────────────────┐
│                    AWS (us-east-1)                   │
│  ┌──────────────────────────────────────────────┐   │
│  │                EKS Cluster                    │   │
│  │  ┌──────────┐  ┌──────────┐  ┌───────────┐  │   │
│  │  │ java-app │  │   api    │  │ dashboard │  │   │
│  │  └──────────┘  └──────────┘  └───────────┘  │   │
│  │                ALB Ingress                    │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │   RDS    │  │   ECR    │  │  Secrets Manager  │  │
│  │Postgres  │  │  repos   │  │   app-secrets     │  │
│  └──────────┘  └──────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────┘
```
EOF

push_repo "Documents" "$DOCS_DIR" "SecureOps project documentation — implementation guide, scope, PPT, proof artifacts"

# ══════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All repositories pushed to GitHub!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "  Terraform  → https://github.com/${GITHUB_USER}/Terraform"
echo "  Kubernetes → https://github.com/${GITHUB_USER}/Kubernetes"
echo "  Helm       → https://github.com/${GITHUB_USER}/Helm"
echo "  ArgoCD     → https://github.com/${GITHUB_USER}/ArgoCD"
echo "  AWS-Cloud  → https://github.com/${GITHUB_USER}/AWS-Cloud"
echo "  Documents  → https://github.com/${GITHUB_USER}/Documents"
echo ""

rm -rf "$TMP_BASE"

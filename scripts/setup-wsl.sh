#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  SecureOps — WSL Ubuntu 22.04 Tool Installer
#  Installs: Java 17, Maven, AWS CLI v2, Terraform, kubectl, Helm
#
#  Run once from WSL:
#    chmod +x scripts/setup-wsl.sh && ./scripts/setup-wsl.sh
# ══════════════════════════════════════════════════════════════
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INSTALL]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}     $*"; }

sudo apt-get update -qq

# ── Java 17 ───────────────────────────────────────────────────
info "Installing Java 17 (OpenJDK)..."
sudo apt-get install -y -qq openjdk-17-jdk
success "Java $(java -version 2>&1 | head -1)"

# ── Maven ─────────────────────────────────────────────────────
info "Installing Maven..."
sudo apt-get install -y -qq maven
success "Maven $(mvn -version 2>/dev/null | head -1)"

# ── AWS CLI v2 ────────────────────────────────────────────────
info "Installing AWS CLI v2..."
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscli
sudo /tmp/awscli/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/awscli
success "AWS CLI $(aws --version)"

# ── Terraform ─────────────────────────────────────────────────
info "Installing Terraform..."
sudo apt-get install -y -qq gnupg software-properties-common
wget -qO- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq terraform
success "Terraform $(terraform version | head -1)"

# ── kubectl ───────────────────────────────────────────────────
info "Installing kubectl..."
KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo /tmp/kubectl \
  "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm /tmp/kubectl
success "kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client | head -1)"

# ── Helm ──────────────────────────────────────────────────────
info "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
success "Helm $(helm version --short)"

# ── jq (handy for parsing AWS output) ────────────────────────
sudo apt-get install -y -qq jq unzip
success "jq installed"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All tools installed! Version summary:${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
java -version 2>&1 | head -1
mvn -version | head -1
aws --version
terraform version | head -1
kubectl version --client --short 2>/dev/null || kubectl version --client | head -1
helm version --short
echo ""
echo "Next step — set your AWS credentials in WSL:"
echo ""
echo "  export AWS_ACCESS_KEY_ID=AKIAxxxxxxxxxxxxxxxxxxxx"
echo "  export AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
echo "  export AWS_DEFAULT_REGION=ap-south-1"
echo ""
echo "Then run:"
echo "  cd /mnt/c/Users/dilip/java-secure-pipeline"
echo "  chmod +x scripts/deploy-aws.sh"
echo "  ./scripts/deploy-aws.sh"
echo ""

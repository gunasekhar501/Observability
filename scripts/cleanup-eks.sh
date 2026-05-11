#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  SecureOps — EKS Full Cleanup + Fresh Fargate Deploy
#  Wipes all EKS resources from AWS and Terraform state, then
#  applies a clean Fargate-only cluster.
#
#  Run from project root:
#    chmod +x scripts/cleanup-eks.sh && ./scripts/cleanup-eks.sh
# ══════════════════════════════════════════════════════════════════
set -uo pipefail

CLUSTER="secureops-eks"
REGION="us-east-1"
TF_DIR="terraform/environments/aws"
ROLES=("secureops-eks-cluster-role" "secureops-eks-node-role" "secureops-eks-fargate-role" "secureops-eks-ebs-csi-role" "secureops-eks-alb-controller-role")

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${BLUE}[CLEANUP]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}     $*"; }
warn()    { echo -e "${YELLOW}[SKIP]${NC}   $*"; }

# ── 1. Delete all node groups ──────────────────────────────────────
info "Deleting all EKS node groups..."
NODEGROUPS=$(aws eks list-nodegroups \
  --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'nodegroups[]' --output text 2>/dev/null || echo "")

for ng in $NODEGROUPS; do
  info "  Deleting node group: $ng"
  aws eks delete-nodegroup \
    --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
    --region "$REGION" 2>/dev/null || true
done

for ng in $NODEGROUPS; do
  info "  Waiting for node group $ng to be deleted (~3 min)..."
  aws eks wait nodegroup-deleted \
    --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
    --region "$REGION" 2>/dev/null || true
  success "  Node group $ng deleted"
done

# ── 2. Delete all Fargate profiles ────────────────────────────────
info "Deleting Fargate profiles..."
PROFILES=$(aws eks list-fargate-profiles \
  --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'fargateProfileNames[]' --output text 2>/dev/null || echo "")

for profile in $PROFILES; do
  info "  Deleting Fargate profile: $profile"
  aws eks delete-fargate-profile \
    --cluster-name "$CLUSTER" --fargate-profile-name "$profile" \
    --region "$REGION" 2>/dev/null || true
  aws eks wait fargate-profile-deleted \
    --cluster-name "$CLUSTER" --fargate-profile-name "$profile" \
    --region "$REGION" 2>/dev/null || true
  success "  Fargate profile $profile deleted"
done

# ── 3. Delete EKS cluster ─────────────────────────────────────────
info "Deleting EKS cluster..."
aws eks delete-cluster --name "$CLUSTER" --region "$REGION" 2>/dev/null || true
aws eks wait cluster-deleted --name "$CLUSTER" --region "$REGION" 2>/dev/null || true
success "Cluster deleted"

# ── 4. Delete IAM roles (detach policies first) ───────────────────
info "Cleaning IAM roles..."
for role in "${ROLES[@]}"; do
  # Detach managed policies
  POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$role" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text 2>/dev/null || echo "")
  for policy in $POLICIES; do
    aws iam detach-role-policy \
      --role-name "$role" --policy-arn "$policy" 2>/dev/null || true
  done

  # Delete inline policies
  INLINE=$(aws iam list-role-policies \
    --role-name "$role" \
    --query 'PolicyNames[]' \
    --output text 2>/dev/null || echo "")
  for policy in $INLINE; do
    aws iam delete-role-policy \
      --role-name "$role" --policy-name "$policy" 2>/dev/null || true
  done

  aws iam delete-role --role-name "$role" 2>/dev/null \
    && success "  Deleted role: $role" \
    || warn "  Role not found: $role"
done

# ── 5. Delete OIDC provider ───────────────────────────────────────
info "Cleaning OIDC providers..."
OIDC_ARNS=$(aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[].Arn' \
  --output text 2>/dev/null || echo "")
for arn in $OIDC_ARNS; do
  if [[ "$arn" == *"eks.us-east-1"* ]]; then
    aws iam delete-open-id-connect-provider \
      --open-id-connect-provider-arn "$arn" 2>/dev/null || true
    success "  Deleted OIDC provider: $arn"
  fi
done

# ── 6. Clear ALL EKS entries from Terraform state ─────────────────
info "Clearing Terraform state..."
cd "$TF_DIR"
terraform state list 2>/dev/null | grep "module.eks" | while read -r resource; do
  terraform state rm "$resource" 2>/dev/null \
    && success "  Removed: $resource" \
    || warn "  Not in state: $resource"
done

# ── 7. Apply fresh Fargate cluster ────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Cleanup complete. Applying fresh Fargate cluster ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""

terraform apply -var="region=us-east-1" -auto-approve

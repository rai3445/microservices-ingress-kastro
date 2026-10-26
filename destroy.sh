#!/usr/bin/env bash
# ==============================================================================
# 🧹 TEARDOWN SCRIPT - Destroy All AWS Resources (EKS, ECS, ALB, ECR, Terraform)
# ==============================================================================
# This script deletes all created resources to ensure you incur $0 ongoing costs:
# 1. Terraform Resources (ECS Fargate, ALB, Target Groups, Security Groups)
# 2. Kubernetes Services & Ingress Load Balancer
# 3. EKS Cluster & EC2 Worker Nodes (kastro-cluster)
# 4. Amazon ECR Repository (techsolutions-app)
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${RED}==================================================================${NC}"
echo -e "${RED}     ⚠️  AWS CLEANUP & RESOURCE TEARDOWN SCRIPT  ⚠️               ${NC}"
echo -e "${RED}==================================================================${NC}"
echo -e "This will delete: EKS cluster, ECS, ALB, and ECR repositories."
read -rp "Are you sure you want to proceed? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]]; then
    echo -e "${GREEN}Teardown cancelled.${NC}"
    exit 0
fi

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-kastro-cluster}"
ECR_REPO_NAME="${ECR_REPO_NAME:-techsolutions-app}"

BIN_DIR="$HOME/.local/bin"
export PATH="$BIN_DIR:$HOME/.local/aws-cli/bin:$PATH"

# 1. Credentials Check
if [[ -z "$AWS_ACCESS_KEY_ID" ]]; then
    read -rp "Enter AWS Access Key ID: " AWS_ACCESS_KEY_ID
    export AWS_ACCESS_KEY_ID
fi
if [[ -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    read -s -rp "Enter AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
    export AWS_SECRET_ACCESS_KEY
    echo ""
fi
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION="$AWS_REGION"

# 2. Destroy Terraform Resources (ECS, ALB, Security Groups)
echo -e "\n${BLUE}[1/4] Checking and Destroying Terraform Resources...${NC}"
if [[ -d "terraform" && -f "terraform/terraform.tfstate" ]]; then
    echo -e "${YELLOW}Running 'terraform destroy'...${NC}"
    (cd terraform && terraform destroy -auto-approve || true)
    echo -e "${GREEN}✓ Terraform resources destroyed.${NC}"
else
    echo -e "${CYAN}No Terraform state file found. Skipping.${NC}"
fi

# 3. Delete Ingress Load Balancer & Kubernetes Services
echo -e "\n${BLUE}[2/4] Removing Kubernetes Ingress Load Balancers...${NC}"
if command -v kubectl &>/dev/null; then
    aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" 2>/dev/null || true
    echo "Deleting Ingress controller service (removes AWS Load Balancer)..."
    kubectl delete svc ingress-nginx-controller -n ingress-nginx --timeout=60s 2>/dev/null || true
    kubectl delete namespace ingress-nginx --timeout=60s 2>/dev/null || true
    echo -e "${GREEN}✓ Load Balancers cleaned up.${NC}"
fi

# 4. Delete EKS Cluster & Worker Nodes
echo -e "\n${BLUE}[3/4] Deleting AWS EKS Cluster ('${EKS_CLUSTER_NAME}')...${NC}"
if command -v eksctl &>/dev/null; then
    CLUSTER_EXISTS=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.status" --output text 2>/dev/null || true)
    if [[ "$CLUSTER_EXISTS" == "ACTIVE" || "$CLUSTER_EXISTS" == "FAILED" ]]; then
        echo -e "${YELLOW}Deleting EKS cluster and nodegroups (this takes ~5-10 minutes)...${NC}"
        eksctl delete cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" || true
        echo -e "${GREEN}✓ EKS Cluster deleted.${NC}"
    else
        echo -e "${CYAN}EKS Cluster '${EKS_CLUSTER_NAME}' does not exist or already deleted.${NC}"
    fi
fi

# 5. Delete Amazon ECR Repository
echo -e "\n${BLUE}[4/4] Deleting Amazon ECR Repository ('${ECR_REPO_NAME}')...${NC}"
if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" &>/dev/null; then
    aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" --force 2>/dev/null || true
    echo -e "${GREEN}✓ ECR repository '${ECR_REPO_NAME}' deleted.${NC}"
else
    echo -e "${CYAN}ECR repository does not exist.${NC}"
fi

echo -e "\n${GREEN}==================================================================${NC}"
echo -e "${GREEN}      🎉 ALL AWS RESOURCES HAVE BEEN COMPLETELY DESTROYED!       ${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo -e "Your account will no longer incur charges for this project."

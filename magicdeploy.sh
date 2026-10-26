#!/usr/bin/env bash
# ==============================================================================
# 🔮 MAGIC DEPLOY SCRIPT - Microservices Application to AWS EKS with Ingress
# ==============================================================================
# INSTRUCTIONS:
# 1. Fill in your AWS credentials in the variables below (or leave blank to be prompted).
# 2. Run: bash magicdeploy.sh
# 3. Sit back and watch your application get built, pushed to ECR, and deployed!
# ==============================================================================

# --- [ CONFIGURATION ] ---
AWS_ACCESS_KEY_ID="PUT_YOUR_AWS_ACCESS_KEY_ID_HERE"
AWS_SECRET_ACCESS_KEY="PUT_YOUR_AWS_SECRET_ACCESS_KEY_HERE"
AWS_REGION="us-east-1"
EKS_CLUSTER_NAME="kastro-cluster"
ECR_REPO_NAME="techsolutions-app"
APP_NAME="techsolutions"

# -------------------------
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}==================================================================${NC}"
echo -e "${CYAN}       🚀 Starting Magic Deploy to AWS (ECR + EKS + Ingress)       ${NC}"
echo -e "${CYAN}==================================================================${NC}"

# 1. Prompt for credentials if placeholders remain
if [[ "$AWS_ACCESS_KEY_ID" == "PUT_YOUR_AWS_ACCESS_KEY_ID_HERE" || -z "$AWS_ACCESS_KEY_ID" ]]; then
    echo -e "${YELLOW}[!] AWS Access Key not set in script.${NC}"
    read -rp "Enter AWS Access Key ID: " AWS_ACCESS_KEY_ID
fi

if [[ "$AWS_SECRET_ACCESS_KEY" == "PUT_YOUR_AWS_SECRET_ACCESS_KEY_HERE" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    echo -e "${YELLOW}[!] AWS Secret Key not set in script.${NC}"
    read -s -rp "Enter AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
    echo ""
fi

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION="$AWS_REGION"

# 2. Setup Local Bin Directory for tools
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"

# 3. Verify / Auto-install Prerequisites
echo -e "\n${BLUE}🔍 Step 1: Checking CLI dependencies...${NC}"

# Check AWS CLI
if ! command -v aws &>/dev/null; then
    echo -e "${YELLOW}Installing AWS CLI...${NC}"
    if [[ "$OSTYPE" == "linux"* ]]; then
        TMP_DIR=$(mktemp -d)
        curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$TMP_DIR/awscliv2.zip"
        unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
        "$TMP_DIR/aws/install" --bin-dir "$BIN_DIR" --install-dir "$HOME/.local/aws-cli" --update 2>/dev/null || \
        sudo "$TMP_DIR/aws/install" --update 2>/dev/null || true
        rm -rf "$TMP_DIR"
    fi
fi

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    echo -e "${YELLOW}Installing kubectl...${NC}"
    curl -sLO "https://dl.k8s.io/release/v1.29.0/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl "$BIN_DIR/"
fi

# Check eksctl
if ! command -v eksctl &>/dev/null; then
    echo -e "${YELLOW}Installing eksctl...${NC}"
    curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
    tar -xzf eksctl_Linux_amd64.tar.gz -C "$BIN_DIR"
    rm -f eksctl_Linux_amd64.tar.gz
fi

# Check Docker
if ! command -v docker &>/dev/null; then
    echo -e "${RED}[ERROR] Docker is not installed or not in PATH. Please start Docker and retry.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All tools are ready!${NC}"

# 4. Authenticate with AWS
echo -e "\n${BLUE}🔐 Step 2: Validating AWS Credentials...${NC}"
CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null) || {
    echo -e "${RED}[ERROR] Failed to authenticate with AWS. Please check your credentials.${NC}"
    exit 1
}
AWS_ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)
echo -e "${GREEN}✓ Connected to AWS Account: $AWS_ACCOUNT_ID (Region: $AWS_REGION)${NC}"

# 5. Setup Amazon ECR
echo -e "\n${BLUE}📦 Step 3: Setting up Amazon ECR (${ECR_REPO_NAME})...${NC}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Ensure ECR repository exists
aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" &>/dev/null || \
aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" --image-scanning-configuration scanOnPush=true >/dev/null
echo -e "${GREEN}✓ ECR repository is ready: ${ECR_REGISTRY}/${ECR_REPO_NAME}${NC}"

# 6. Build and Push Docker Image
echo -e "\n${BLUE}🐳 Step 4: Building & Pushing Docker Image...${NC}"
IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%s)
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO_NAME}:${IMAGE_TAG}"
IMAGE_LATEST="${ECR_REGISTRY}/${ECR_REPO_NAME}:latest"

docker build -t "$IMAGE_URI" -t "$IMAGE_LATEST" .
docker push "$IMAGE_URI"
docker push "$IMAGE_LATEST"
echo -e "${GREEN}✓ Image successfully pushed to ECR: ${IMAGE_URI}${NC}"

# 7. Check or Create EKS Cluster
echo -e "\n${BLUE}☸️  Step 5: Checking EKS Cluster '${EKS_CLUSTER_NAME}'...${NC}"
CLUSTER_STATUS=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.status" --output text 2>/dev/null || true)

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo -e "${YELLOW}[!] EKS Cluster '${EKS_CLUSTER_NAME}' not found or not active.${NC}"
    echo -e "${YELLOW}⚡ Creating EKS cluster using eksctl (this takes ~12-15 minutes, please wait)...${NC}"
    eksctl create cluster \
        --name "$EKS_CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --node-type t2.medium \
        --nodes 2 \
        --zones "${AWS_REGION}a,${AWS_REGION}b"
    echo -e "${GREEN}✓ EKS Cluster created successfully!${NC}"
else
    echo -e "${GREEN}✓ EKS Cluster '${EKS_CLUSTER_NAME}' is ACTIVE.${NC}"
fi

# 8. Configure Kubeconfig
echo -e "\n${BLUE}⚙️  Step 6: Updating kubeconfig...${NC}"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
kubectl get nodes

# 9. Ensure NGINX Ingress Controller is installed
echo -e "\n${BLUE}🌐 Step 7: Ensuring AWS NGINX Ingress Controller is installed...${NC}"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/aws/deploy.yaml
echo "Waiting for ingress-nginx controller pod rollout..."
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s || true

# 10. Update and Deploy Application Manifests
echo -e "\n${BLUE}🚀 Step 8: Deploying Application & Ingress to Kubernetes...${NC}"
sed -i.bak "s|image: .*|image: ${IMAGE_URI}|g" k8s/deployment.yaml
rm -f k8s/deployment.yaml.bak

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/ingress.yaml
kubectl rollout status "deployment/${APP_NAME}-deployment" --timeout=180s

# 11. Retrieve Load Balancer URL
echo -e "\n${BLUE}⏳ Step 9: Waiting for AWS Load Balancer Hostname...${NC}"
INGRESS_HOST=""
for i in {1..30}; do
    INGRESS_HOST=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -n "$INGRESS_HOST" ]; then
        break
    fi
    echo -n "."
    sleep 10
done
echo ""

# 12. Final Output
if [ -n "$INGRESS_HOST" ]; then
    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}             🎉 MAGIC DEPLOYMENT SUCCESSFUL! 🎉                   ${NC}"
    echo -e "${GREEN}==================================================================${NC}"
    echo -e "Application URL: ${CYAN}http://${INGRESS_HOST}${NC}\n"
    echo -e "Available Routes:"
    echo -e "  🏠 Home:     ${CYAN}http://${INGRESS_HOST}/${NC}"
    echo -e "  ℹ️  About:    ${CYAN}http://${INGRESS_HOST}/about${NC}"
    echo -e "  💼 Services: ${CYAN}http://${INGRESS_HOST}/services${NC}"
    echo -e "  📬 Contact:  ${CYAN}http://${INGRESS_HOST}/contact${NC}"
    echo -e "${GREEN}==================================================================${NC}"
else
    echo -e "${YELLOW}⚠️  Load Balancer Hostname is still provisioning by AWS.${NC}"
    echo -e "Run the following command in 2-3 minutes to check:"
    echo -e "${CYAN}kubectl get svc ingress-nginx-controller -n ingress-nginx${NC}"
fi

# ==============================================================================
# MAGIC DEPLOY SCRIPT (PowerShell) - AWS EKS + Amazon ECR + Ingress
# ==============================================================================
# INSTRUCTIONS:
# 1. Fill in your AWS credentials below (or run and you will be prompted).
# 2. Run: .\magicdeploy.ps1
# 3. Sit back and watch your application get built, pushed to ECR, and deployed!
# ==============================================================================

param(
    [string]$AWS_ACCESS_KEY_ID = "PUT_YOUR_AWS_ACCESS_KEY_ID_HERE",
    [string]$AWS_SECRET_ACCESS_KEY = "PUT_YOUR_AWS_SECRET_ACCESS_KEY_HERE",
    [string]$AWS_REGION = "us-east-1",
    [string]$EKS_CLUSTER_NAME = "kastro-cluster",
    [string]$ECR_REPO_NAME = "techsolutions-app",
    [string]$APP_NAME = "techsolutions"
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "       Starting Magic Deploy to AWS (ECR + EKS + Ingress)         " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Prompt for credentials if placeholders remain
if ($AWS_ACCESS_KEY_ID -eq "PUT_YOUR_AWS_ACCESS_KEY_ID_HERE" -or [string]::IsNullOrWhiteSpace($AWS_ACCESS_KEY_ID)) {
    $AWS_ACCESS_KEY_ID = Read-Host "Enter AWS Access Key ID"
}
if ($AWS_SECRET_ACCESS_KEY -eq "PUT_YOUR_AWS_SECRET_ACCESS_KEY_HERE" -or [string]::IsNullOrWhiteSpace($AWS_SECRET_ACCESS_KEY)) {
    $secureKey = Read-Host "Enter AWS Secret Access Key" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $AWS_SECRET_ACCESS_KEY = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
}

$env:AWS_ACCESS_KEY_ID = $AWS_ACCESS_KEY_ID
$env:AWS_SECRET_ACCESS_KEY = $AWS_SECRET_ACCESS_KEY
$env:AWS_DEFAULT_REGION = $AWS_REGION
$env:AWS_REGION = $AWS_REGION

# Setup Local Bin Directory
$binDir = Join-Path $HOME ".local\bin"
if (!(Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
$pyScripts = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\Scripts"
$appDataPython = Join-Path $env:APPDATA "Python\Python312\Scripts"
$env:Path = "$binDir;$pyScripts;$appDataPython;C:\Program Files\Amazon\AWSCLIV2;$env:Path"

# 2. Check / Install AWS CLI if missing
Write-Host "`n[Step 1] Checking CLI dependencies..." -ForegroundColor Blue
if (!(Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "AWS CLI not found. Installing awscli via pip..." -ForegroundColor Yellow
    python -m pip install --quiet awscli
}

# Check kubectl
if (!(Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "Installing kubectl..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://dl.k8s.io/release/v1.29.0/bin/windows/amd64/kubectl.exe" -OutFile "$binDir\kubectl.exe"
}

# Check eksctl
if (!(Get-Command eksctl -ErrorAction SilentlyContinue)) {
    Write-Host "Installing eksctl..." -ForegroundColor Yellow
    $zipPath = Join-Path $env:TEMP "eksctl.zip"
    Invoke-WebRequest -Uri "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Windows_amd64.zip" -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $binDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

# Check Docker
if (!(Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Docker is not installed or not running. Please launch Docker Desktop and retry." -ForegroundColor Red
    Exit 1
}

Write-Host "[OK] All dependencies verified!" -ForegroundColor Green

# 3. Authenticate with AWS
Write-Host "`n[Step 2] Validating AWS Credentials..." -ForegroundColor Blue
$callerOutput = aws sts get-caller-identity --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] AWS Authentication Failed:" -ForegroundColor Red
    Write-Host $callerOutput -ForegroundColor Red
    Exit 1
}
$identityJson = $callerOutput | ConvertFrom-Json
$AWS_ACCOUNT_ID = $identityJson.Account
Write-Host "[OK] Connected to AWS Account: $AWS_ACCOUNT_ID (Region: $AWS_REGION)" -ForegroundColor Green

# 4. Amazon ECR Setup
Write-Host "`n[Step 3] Setting up Amazon ECR ($ECR_REPO_NAME)..." -ForegroundColor Blue
$ECR_REGISTRY = "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
$ecrPassword = aws ecr get-login-password --region $AWS_REGION
$ecrPassword | docker login --username AWS --password-stdin $ECR_REGISTRY

try {
    aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $AWS_REGION 2>$null | Out-Null
} catch {
    aws ecr create-repository --repository-name $ECR_REPO_NAME --region $AWS_REGION --image-scanning-configuration scanOnPush=true | Out-Null
}
Write-Host "[OK] ECR repository is ready: $ECR_REGISTRY/$ECR_REPO_NAME" -ForegroundColor Green

# 5. Build and Push Docker Image
Write-Host "`n[Step 4] Building and Pushing Docker Image..." -ForegroundColor Blue
$IMAGE_TAG = (git rev-parse --short HEAD 2>$null)
if (!$IMAGE_TAG) { $IMAGE_TAG = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
$IMAGE_URI = "$ECR_REGISTRY/${ECR_REPO_NAME}:${IMAGE_TAG}"
$IMAGE_LATEST = "$ECR_REGISTRY/${ECR_REPO_NAME}:latest"

docker build -t $IMAGE_URI -t $IMAGE_LATEST .
docker push $IMAGE_URI
docker push $IMAGE_LATEST
Write-Host "[OK] Image successfully pushed to Amazon ECR: $IMAGE_URI" -ForegroundColor Green

# 6. Check or Create EKS Cluster
Write-Host "`n[Step 5] Checking EKS Cluster '$EKS_CLUSTER_NAME'..." -ForegroundColor Blue
$clusterStatus = ""
try {
    $clusterStatus = aws eks describe-cluster --name $EKS_CLUSTER_NAME --region $AWS_REGION --query "cluster.status" --output text 2>$null
} catch {}

if ($clusterStatus -ne "ACTIVE") {
    Write-Host "[!] EKS Cluster '$EKS_CLUSTER_NAME' not found or not active." -ForegroundColor Yellow
    Write-Host "[*] Creating EKS cluster using eksctl (takes ~12-15 minutes, please wait)..." -ForegroundColor Yellow
    eksctl create cluster `
        --name $EKS_CLUSTER_NAME `
        --region $AWS_REGION `
        --node-type t2.medium `
        --nodes 2 `
        --zones "$($AWS_REGION)a,$($AWS_REGION)b"
    Write-Host "[OK] EKS Cluster created successfully!" -ForegroundColor Green
} else {
    Write-Host "[OK] EKS Cluster '$EKS_CLUSTER_NAME' is ACTIVE." -ForegroundColor Green
}

# 7. Update Kubeconfig
Write-Host "`n[Step 6] Updating kubeconfig..." -ForegroundColor Blue
aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME
kubectl get nodes

# 8. Ensure NGINX Ingress Controller is installed
Write-Host "`n[Step 7] Ensuring AWS NGINX Ingress Controller is installed..." -ForegroundColor Blue
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/aws/deploy.yaml
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

# 9. Update & Deploy Application Manifests
Write-Host "`n[Step 8] Deploying Application and Ingress to Kubernetes..." -ForegroundColor Blue
$deployContent = Get-Content k8s/deployment.yaml -Raw
$deployContent = $deployContent -replace 'image: .*', "image: $IMAGE_URI"
Set-Content -Path k8s/deployment.yaml -Value $deployContent

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/ingress.yaml
kubectl rollout status "deployment/$APP_NAME-deployment" --timeout=180s

# 10. Retrieve Load Balancer URL
Write-Host "`n[Step 9] Waiting for AWS Load Balancer Hostname..." -ForegroundColor Blue
$ingressHost = ""
for ($i = 1; $i -le 30; $i++) {
    $ingressHost = (kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null)
    if (![string]::IsNullOrWhiteSpace($ingressHost)) { break }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 10
}
Write-Host ""

# 11. Final Output
if (![string]::IsNullOrWhiteSpace($ingressHost)) {
    Write-Host "`n==================================================================" -ForegroundColor Green
    Write-Host "             MAGIC DEPLOYMENT SUCCESSFUL!                         " -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "Application URL: http://$ingressHost`n" -ForegroundColor Cyan
    Write-Host "Available Routes:"
    Write-Host "  Home:     http://$ingressHost/" -ForegroundColor Cyan
    Write-Host "  About:    http://$ingressHost/about" -ForegroundColor Cyan
    Write-Host "  Services: http://$ingressHost/services" -ForegroundColor Cyan
    Write-Host "  Contact:  http://$ingressHost/contact" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Green
} else {
    Write-Host "[!] Load Balancer Hostname is still provisioning by AWS." -ForegroundColor Yellow
    Write-Host "Run this command in 2 minutes: kubectl get svc ingress-nginx-controller -n ingress-nginx" -ForegroundColor Cyan
}

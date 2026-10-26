
# ==============================================================================
# AWS CLEANUP & RESOURCE TEARDOWN SCRIPT
# Deletes Terraform resources, Kubernetes Ingress, EKS cluster, and ECR repo
# ==============================================================================

$ErrorActionPreference = "Continue"

$Red    = "Red"
$Green  = "Green"
$Yellow = "Yellow"
$Cyan   = "Cyan"
$Blue   = "Blue"

Write-Host "==================================================================" -ForegroundColor $Red
Write-Host "       AWS CLEANUP & RESOURCE TEARDOWN SCRIPT" -ForegroundColor $Red
Write-Host "==================================================================" -ForegroundColor $Red

Write-Host "This script may permanently delete AWS resources." -ForegroundColor $Yellow
Write-Host "Check your AWS account and region before continuing."

$answer = Read-Host "Are you sure you want to proceed? Type yes to continue"

if ($answer -notin @("yes", "y")) {
    Write-Host "Teardown cancelled." -ForegroundColor $Green
    exit 0
}

# Configuration
$AWS_REGION = if ($env:AWS_REGION) {
    $env:AWS_REGION
} else {
    "us-east-1"
}

$EKS_CLUSTER_NAME = if ($env:EKS_CLUSTER_NAME) {
    $env:EKS_CLUSTER_NAME
} else {
    "kastro-cluster"
}

$ECR_REPO_NAME = if ($env:ECR_REPO_NAME) {
    $env:ECR_REPO_NAME
} else {
    "techsolutions-app"
}

$env:AWS_DEFAULT_REGION = $AWS_REGION
$env:AWS_REGION = $AWS_REGION

# Add common local executable directories to PATH
$binDir = Join-Path $HOME ".local\bin"
$awsBinDir = Join-Path $HOME ".local\aws-cli\bin"

$env:PATH = "$binDir;$awsBinDir;$env:PATH"

# Helper: run a command and report its exit code
function Invoke-CleanupCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $Command @Arguments
    return $LASTEXITCODE
}

# 1. Verify AWS CLI and credentials
Write-Host "`n[1/4] Checking AWS CLI and credentials..." -ForegroundColor $Blue

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "AWS CLI not found. Install AWS CLI first." -ForegroundColor $Red
    exit 1
}

# Use configured AWS CLI credentials, an AWS profile, SSO,
# or environment credentials. Avoid pasting secrets into the script.
$identity = & aws sts get-caller-identity --region $AWS_REGION --output json 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "AWS authentication failed." -ForegroundColor $Red
    Write-Host "Configure credentials using 'aws configure' or 'aws sso login'." -ForegroundColor $Yellow
    exit 1
}

$identityObject = $identity | ConvertFrom-Json

Write-Host "Authenticated AWS account: $($identityObject.Account)" -ForegroundColor $Green
Write-Host "Region: $AWS_REGION" -ForegroundColor $Cyan

$expectedAccount = Read-Host "Enter the AWS account ID above to confirm"

if ($expectedAccount -ne $identityObject.Account) {
    Write-Host "Account ID mismatch. Cleanup cancelled." -ForegroundColor $Red
    exit 1
}

# 2. Destroy Terraform resources
Write-Host "`n[2/4] Checking Terraform resources..." -ForegroundColor $Blue

$terraformDir = Join-Path (Get-Location) "terraform"
$terraformState = Join-Path $terraformDir "terraform.tfstate"

if ((Test-Path $terraformDir) -and (Test-Path $terraformState)) {
    if (Get-Command terraform -ErrorAction SilentlyContinue) {
        Write-Host "Running terraform destroy..." -ForegroundColor $Yellow

        Push-Location $terraformDir
        try {
            & terraform destroy -auto-approve
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Terraform destroy failed. Check Terraform output and state." -ForegroundColor $Red
            } else {
                Write-Host "Terraform destroy completed." -ForegroundColor $Green
            }
        }
        finally {
            Pop-Location
        }
    } else {
        Write-Host "Terraform is not installed. Skipping Terraform cleanup." -ForegroundColor $Red
    }
} else {
    Write-Host "Local Terraform state not found. Skipping Terraform cleanup." -ForegroundColor $Cyan
    Write-Host "If using remote state, inspect that state before deleting resources." -ForegroundColor $Yellow
}

# 3. Remove Kubernetes Ingress load balancer resources
Write-Host "`n[3/4] Removing Kubernetes Ingress resources..." -ForegroundColor $Blue

if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    $null = & aws eks update-kubeconfig `
        --region $AWS_REGION `
        --name $EKS_CLUSTER_NAME 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Deleting Ingress controller service..." -ForegroundColor $Yellow

        & kubectl delete service ingress-nginx-controller `
            -n ingress-nginx --timeout=60s --ignore-not-found=true

        & kubectl delete namespace ingress-nginx `
            --timeout=60s --ignore-not-found=true

        Write-Host "Ingress cleanup commands completed. Verify load balancers in AWS." -ForegroundColor $Green
    } else {
        Write-Host "Could not connect to the EKS cluster. Skipping Kubernetes cleanup." -ForegroundColor $Yellow
    }
} else {
    Write-Host "kubectl not found. Skipping Kubernetes cleanup." -ForegroundColor $Yellow
}

# 4. Delete EKS cluster and ECR repository
Write-Host "`n[4/4] Deleting EKS cluster and ECR repository..." -ForegroundColor $Blue

if (Get-Command eksctl -ErrorAction SilentlyContinue) {
    $clusterStatus = & aws eks describe-cluster `
        --name $EKS_CLUSTER_NAME `
        --region $AWS_REGION `
        --query "cluster.status" `
        --output text 2>$null

    if ($LASTEXITCODE -eq 0 -and $clusterStatus -in @("ACTIVE", "FAILED")) {
        Write-Host "Deleting EKS cluster: $EKS_CLUSTER_NAME" -ForegroundColor $Yellow
        Write-Host "This can take several minutes."

        & eksctl delete cluster `
            --name $EKS_CLUSTER_NAME `
            --region $AWS_REGION

        if ($LASTEXITCODE -eq 0) {
            Write-Host "EKS deletion command completed." -ForegroundColor $Green
        } else {
            Write-Host "EKS deletion failed. Check AWS resources manually." -ForegroundColor $Red
        }
    } else {
        Write-Host "EKS cluster not found or not in a deletable status." -ForegroundColor $Cyan
    }
} else {
    Write-Host "eksctl not found. Skipping EKS deletion." -ForegroundColor $Yellow
}

# Delete ECR repository and its images
$null = & aws ecr describe-repositories `
    --repository-names $ECR_REPO_NAME `
    --region $AWS_REGION 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "Deleting ECR repository: $ECR_REPO_NAME" -ForegroundColor $Yellow

    & aws ecr delete-repository `
        --repository-name $ECR_REPO_NAME `
        --region $AWS_REGION `
        --force

    if ($LASTEXITCODE -eq 0) {
        Write-Host "ECR repository deleted." -ForegroundColor $Green
    } else {
        Write-Host "ECR deletion failed. Check AWS permissions and repository status." -ForegroundColor $Red
    }
} else {
    Write-Host "ECR repository not found or inaccessible." -ForegroundColor $Cyan
}

Write-Host "`n==================================================================" -ForegroundColor $Green
Write-Host "CLEANUP COMMANDS FINISHED" -ForegroundColor $Green
Write-Host "==================================================================" -ForegroundColor $Green
Write-Host "Important: Verify remaining resources and billing in AWS Console."
Write-Host "Check EC2, EKS, ECS, ELB, NAT Gateway, EBS, ECR, and VPC resources."

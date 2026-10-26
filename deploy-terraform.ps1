# ==============================================================================
# HASSLE-FREE 1-CLICK TERRAFORM DEPLOYMENT (AWS ECS Fargate + ALB)
# ==============================================================================
$ErrorActionPreference = "Stop"

$binDir = Join-Path $HOME ".local\bin"
$pyScripts = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\Scripts"
$env:Path = "$binDir;$pyScripts;C:\Program Files\Amazon\AWSCLIV2;$env:Path"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   Starting Hassle-Free Terraform Deploy (AWS ECS Fargate)        " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

Set-Location (Join-Path $PSScriptRoot "terraform")

Write-Host "`n[1/2] Applying Terraform configuration..." -ForegroundColor Blue
terraform apply -auto-approve

Write-Host "`n[2/2] Fetching Live Service Links..." -ForegroundColor Blue
$albUrl = (terraform output -raw load_balancer_dns 2>$null)

if (![string]::IsNullOrWhiteSpace($albUrl)) {
    Write-Host "`n==================================================================" -ForegroundColor Green
    Write-Host "             APPLICATION FULLY DEPLOYED!                          " -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "Load Balancer: http://$albUrl`n" -ForegroundColor Cyan
    Write-Host "Live Endpoints:" -ForegroundColor Green
    Write-Host "  Home:     http://$albUrl/" -ForegroundColor Cyan
    Write-Host "  About:    http://$albUrl/about" -ForegroundColor Cyan
    Write-Host "  Services: http://$albUrl/services" -ForegroundColor Cyan
    Write-Host "  Contact:  http://$albUrl/contact" -ForegroundColor Cyan
    Write-Host "==================================================================`n" -ForegroundColor Green
} else {
    Write-Host "[!] Could not fetch ALB DNS. Run terraform output to view." -ForegroundColor Yellow
}

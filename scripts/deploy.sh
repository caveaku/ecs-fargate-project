#!/usr/bin/env bash
# scripts/deploy.sh
# Manual deploy helper — builds, pushes, and deploys a new image to ECS.
#
# Usage:
#   ./scripts/deploy.sh [environment]
#
# Examples:
#   ./scripts/deploy.sh development
#   ./scripts/deploy.sh production

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Defaults ───────────────────────────────────────────────────
ENVIRONMENT="${1:-development}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
APP_DIR="${PROJECT_ROOT}/app"

# ── Validate environment ───────────────────────────────────────
case "$ENVIRONMENT" in
  development|staging|production) ;;
  *) error "Invalid environment '${ENVIRONMENT}'. Must be: development | staging | production" ;;
esac

info "Deploy target: ${ENVIRONMENT}"

# ── Check prerequisites ────────────────────────────────────────
for cmd in aws docker terraform; do
  command -v "$cmd" &>/dev/null || error "'${cmd}' not found. Please install it."
done

aws sts get-caller-identity &>/dev/null || error "AWS CLI not configured. Run: aws configure"

# ── Read values from Terraform outputs ────────────────────────
info "Reading Terraform outputs..."
cd "${TERRAFORM_DIR}"

ECR_REPO=$(terraform output -raw ecr_repository_url 2>/dev/null) \
  || error "Terraform outputs not available. Run: terraform apply"

CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
APP_URL=$(terraform output -raw app_url)

info "ECR Repo : ${ECR_REPO}"
info "Cluster  : ${CLUSTER}"
info "Service  : ${SERVICE}"
info "Region   : ${AWS_REGION}"

# ── Authenticate with ECR ──────────────────────────────────────
info "Authenticating with ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REPO}" \
  || error "ECR login failed"
success "ECR login successful"

# ── Build Docker image ─────────────────────────────────────────
SHORT_SHA=$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "local")
IMAGE_TAG="${SHORT_SHA}"

info "Building Docker image (tag: ${IMAGE_TAG})..."
docker build \
  --platform linux/amd64 \
  --build-arg APP_VERSION="${IMAGE_TAG}" \
  -t "${ECR_REPO}:${IMAGE_TAG}" \
  -t "${ECR_REPO}:latest" \
  "${APP_DIR}" \
  || error "Docker build failed"
success "Image built: ${ECR_REPO}:${IMAGE_TAG}"

# ── Push to ECR ────────────────────────────────────────────────
info "Pushing image to ECR..."
docker push "${ECR_REPO}:${IMAGE_TAG}"
docker push "${ECR_REPO}:latest"
success "Image pushed to ECR"

# ── Force new ECS deployment ───────────────────────────────────
info "Triggering ECS deployment..."
aws ecs update-service \
  --cluster  "${CLUSTER}" \
  --service  "${SERVICE}" \
  --force-new-deployment \
  --region   "${AWS_REGION}" \
  --output   text \
  --query    'service.serviceName' \
  > /dev/null

info "Waiting for tasks to stabilise (this may take a few minutes)..."
aws ecs wait services-stable \
  --cluster  "${CLUSTER}" \
  --services "${SERVICE}" \
  --region   "${AWS_REGION}" \
  || error "ECS deployment failed — check CloudWatch logs"

success "Deployment complete!"
echo ""
echo -e "  ${GREEN}App URL:${NC} ${APP_URL}"
echo ""

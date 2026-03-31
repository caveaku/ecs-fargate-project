#!/usr/bin/env bash
# scripts/setup-iam.sh
# Creates a dedicated IAM user + access keys for GitHub Actions.
# The generated keys are added as GitHub Actions secrets.
#
# Usage:
#   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
#   export GITHUB_ORG="your-github-org"
#   export GITHUB_REPO="ecs-fargate-project"
#   export PROJECT_NAME="myapp"
#   chmod +x scripts/setup-iam.sh
#   ./scripts/setup-iam.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Validate required env vars ─────────────────────────────────
: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${GITHUB_ORG:?Set GITHUB_ORG}"
: "${GITHUB_REPO:?Set GITHUB_REPO}"
: "${PROJECT_NAME:?Set PROJECT_NAME}"

AWS_REGION="${AWS_REGION:-us-east-1}"
IAM_USER="${PROJECT_NAME}-github-actions"

info "Creating IAM user: ${IAM_USER}"

# ── Create IAM user ────────────────────────────────────────────
aws iam create-user --user-name "${IAM_USER}" \
  --tags Key=Project,Value="${PROJECT_NAME}" Key=ManagedBy,Value=script \
  2>/dev/null || warn "User ${IAM_USER} already exists — skipping creation"

# ── Inline policy: minimum permissions needed ──────────────────
info "Attaching least-privilege policy to ${IAM_USER}..."

cat > /tmp/github-actions-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "ECRPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:DescribeRepositories"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${PROJECT_NAME}-*"
    },
    {
      "Sid": "ECSDescribe",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:RegisterTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECSUpdateService",
      "Effect": "Allow",
      "Action": ["ecs:UpdateService"],
      "Resource": "arn:aws:ecs:${AWS_REGION}:${AWS_ACCOUNT_ID}:service/${PROJECT_NAME}-*/${PROJECT_NAME}-*"
    },
    {
      "Sid": "PassRolesToECS",
      "Effect": "Allow",
      "Action": ["iam:PassRole"],
      "Resource": [
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT_NAME}-*-execution-role",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT_NAME}-*-task-role"
      ]
    },
    {
      "Sid": "ALBDescribe",
      "Effect": "Allow",
      "Action": ["elasticloadbalancing:DescribeLoadBalancers"],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name "${IAM_USER}" \
  --policy-name "${PROJECT_NAME}-github-actions-policy" \
  --policy-document file:///tmp/github-actions-policy.json

rm /tmp/github-actions-policy.json
success "Policy attached"

# ── Create access keys ─────────────────────────────────────────
info "Creating access keys for ${IAM_USER}..."

KEYS=$(aws iam create-access-key --user-name "${IAM_USER}")
ACCESS_KEY_ID=$(echo "${KEYS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['AccessKey']['AccessKeyId'])")
SECRET_ACCESS_KEY=$(echo "${KEYS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['AccessKey']['SecretAccessKey'])")

# ── Output ─────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
success "IAM user and access keys created!"
echo ""
echo "Add the following secrets to your GitHub repository:"
echo "  Repo → Settings → Secrets and variables → Actions → New repository secret"
echo ""
echo -e "  Secret name  : ${GREEN}AWS_ACCESS_KEY_ID${NC}"
echo -e "  Secret value : ${YELLOW}${ACCESS_KEY_ID}${NC}"
echo ""
echo -e "  Secret name  : ${GREEN}AWS_SECRET_ACCESS_KEY${NC}"
echo -e "  Secret value : ${YELLOW}${SECRET_ACCESS_KEY}${NC}"
echo ""
echo "Also add this repository variable (not a secret):"
echo -e "  Variable name : ${GREEN}PROJECT_NAME${NC}"
echo -e "  Variable value: ${YELLOW}${PROJECT_NAME}${NC}"
echo "════════════════════════════════════════════════════════"
echo ""
warn "Store these credentials securely. They will NOT be shown again."
warn "Rotate them periodically via: aws iam create-access-key --user-name ${IAM_USER}"

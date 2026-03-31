# ECS Fargate — Node.js Production Stack

> Deploys a containerised Node.js application on **AWS ECS Fargate** with full
> networking, load balancing, auto-scaling, observability, and a GitHub Actions
> CI/CD pipeline.

---

## Architecture

```
                          ┌──────────────────────────────┐
                          │         INTERNET              │
                          └──────────────┬───────────────┘
                                         │ HTTP/HTTPS
                          ┌──────────────▼───────────────┐
                          │   Application Load Balancer   │
                          │       (public subnets)        │
                          │  ┌──────────┐ ┌──────────┐   │
                          │  │  AZ-A    │ │  AZ-B    │   │
                          └──┴────┬─────┴─┴─────┬────┘───┘
                                  │             │
                    ──────────────┼─────────────┼──────── private subnets
                                  │             │
                    ┌─────────────▼─────────────▼──────┐
                    │          ECS Fargate Service       │
                    │    (auto-scaling: 1–10 tasks)      │
                    │  ┌──────────────┐ ┌────────────┐  │
                    │  │  Task (AZ-A) │ │ Task (AZ-B)│  │
                    │  │  Node.js app │ │ Node.js app│  │
                    │  └──────┬───────┘ └─────┬──────┘  │
                    └─────────┼───────────────┼──────────┘
                              │               │
                    ──────────┼───────────────┼──────────────
                              ▼               ▼
                    ┌──────────────────────────────────────┐
                    │            AWS Services               │
                    │  ECR (images)  │  CloudWatch (logs)   │
                    │  Secrets Mgr   │  Auto Scaling        │
                    └──────────────────────────────────────┘
```

### What Gets Deployed

| Layer | Resource | Notes |
|-------|----------|-------|
| Networking | VPC, 2 public + 2 private subnets, IGW, NAT GW, route tables | Multi-AZ |
| Security | ALB Security Group, ECS Security Group | Least-privilege ingress |
| Registry | ECR repository + lifecycle policy (keep 10 images) | Scan on push |
| Compute | ECS Cluster (Fargate + Fargate Spot), Task Definition, Service | 2 tasks default |
| Load Balancer | ALB, Target Group, HTTP (+ optional HTTPS) listener | Health check on `/health` |
| Auto-scaling | CPU (60%) + Memory (70%) target tracking policies | 1–10 tasks |
| Observability | CloudWatch Log Group, CPU-high + unhealthy-hosts alarms | 30-day retention |
| IAM | ECS Execution Role, ECS Task Role | Secrets Manager + ECS Exec access |

---

## Project Structure

```
ecs-fargate-project/
├── app/                            # Node.js Express application
│   ├── server.js                   # Entry point — / · /health · /info
│   ├── package.json
│   ├── Dockerfile                  # Multi-stage image (node:20-alpine)
│   └── .dockerignore
├── terraform/                      # All AWS infrastructure as code
│   ├── main.tf                     # VPC · ECR · IAM · ECS · ALB · scaling
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars            # Your values (gitignored)
│   └── terraform.tfvars.example   # Template
├── .github/
│   └── workflows/
│       └── deploy.yml              # CI/CD: test → build → push → deploy
└── scripts/
    ├── deploy.sh                   # Manual deploy helper
    └── setup-iam.sh               # Create GitHub Actions IAM user + keys
```

---

## Prerequisites

| Tool      | Minimum version |
|-----------|-----------------|
| AWS CLI   | 2.x             |
| Terraform | 1.5.0           |
| Docker    | 24.x            |
| Node.js   | 20.x            |

Verify:
```bash
aws --version
terraform version
docker --version
node --version
```

---

## Quick Start

### 1 — Configure AWS credentials

```bash
aws configure
aws sts get-caller-identity   # confirm identity
```

### 2 — Set Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set project_name, environment, aws_region
```

### 3 — Provision infrastructure

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output              # note ECR URL, ALB DNS, cluster name
```

### 4 — Build & push the Docker image

```bash
ECR_REPO=$(terraform output -raw ecr_repository_url)
AWS_REGION=$(terraform output -raw aws_region)

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REPO"

docker build --platform linux/amd64 -t "$ECR_REPO:latest" ../app
docker push "$ECR_REPO:latest"
```

### 5 — Deploy to ECS

```bash
cd ..
chmod +x scripts/deploy.sh
./scripts/deploy.sh development    # or: staging | production
```

The script reads all values from Terraform outputs — no manual copy-paste needed.

---

## CI/CD — GitHub Actions

The pipeline in `.github/workflows/deploy.yml` runs automatically on push:

```
push to develop  →  deploy to development
push to staging  →  deploy to staging
push to main     →  deploy to production
```

### Pipeline stages

```
resolve-env  →  test  →  build-and-push  →  deploy
                              │                 │
                         ECR + Trivy       ECS rolling
                         image scan         update
```

### One-time setup

**Step 1** — Create a least-privilege IAM user for GitHub Actions:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GITHUB_ORG="your-github-org"
export GITHUB_REPO="ecs-fargate-project"
export PROJECT_NAME="myapp"

chmod +x scripts/setup-iam.sh
./scripts/setup-iam.sh
```

**Step 2** — Add secrets to your GitHub repository:

`Settings → Secrets and variables → Actions → New repository secret`

| Name | Value |
|------|-------|
| `AWS_ACCESS_KEY_ID` | From script output |
| `AWS_SECRET_ACCESS_KEY` | From script output |

**Step 3** — Add a repository variable (not a secret):

| Name | Value |
|------|-------|
| `PROJECT_NAME` | e.g. `myapp` |

**Step 4** — Push to trigger a deployment:

```bash
git push origin main
```

---

## Application Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /` | App info: hostname, version, environment |
| `GET /health` | ALB health check — always returns `200 OK` |
| `GET /info` | Runtime metrics: memory, uptime, Node version |

---

## Observability

### Live logs

```bash
aws logs tail /ecs/myapp-development --follow
```

### Shell into a running task (ECS Exec)

```bash
CLUSTER="myapp-development"
TASK=$(aws ecs list-tasks \
  --cluster "$CLUSTER" \
  --service-name "$CLUSTER" \
  --query 'taskArns[0]' --output text)

aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task    "$TASK" \
  --container myapp \
  --interactive \
  --command "/bin/sh"
```

### CloudWatch alarms

| Alarm | Trigger |
|-------|---------|
| `myapp-development-cpu-high` | CPU > 80% for 2 consecutive minutes |
| `myapp-development-unhealthy-hosts` | Any ALB target reports unhealthy |

---

## Cost Estimate (development, us-east-1)

| Resource | ~Monthly |
|----------|----------|
| Fargate — 0.25 vCPU, 512 MB × 2 tasks | $15 |
| NAT Gateway — single | $35 |
| Application Load Balancer | $20 |
| ECR + CloudWatch Logs | $3 |
| **Total** | **~$73** |

> **Tip:** Switch `single_nat_gateway = false` only for production; set
> `desired_count = 1` in development to halve the Fargate cost.

---

## Tear Down

```bash
cd terraform
terraform destroy
```

> ALB deletion protection is automatically enabled in production (`environment = "production"`).
> Disable it first if needed:
> ```bash
> aws elbv2 modify-load-balancer-attributes \
>   --load-balancer-arn <ALB_ARN> \
>   --attributes Key=deletion_protection.enabled,Value=false
> ```

---

## Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `project_name` | — | Resource name prefix (required) |
| `environment` | `development` | `development` / `staging` / `production` |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `single_nat_gateway` | `true` | Use one NAT GW (dev) or one per AZ (prod) |
| `task_cpu` | `256` | Fargate CPU units |
| `task_memory` | `512` | Fargate memory (MiB) |
| `desired_count` | `2` | Initial task count |
| `autoscaling_min_capacity` | `1` | Minimum tasks |
| `autoscaling_max_capacity` | `10` | Maximum tasks |
| `autoscaling_cpu_target` | `60` | CPU % to trigger scale-out |
| `autoscaling_memory_target` | `70` | Memory % to trigger scale-out |
| `acm_certificate_arn` | `""` | ACM cert ARN for HTTPS listener |
| `log_retention_days` | `30` | CloudWatch log retention |

# Desafio Semana 4 — AWS Infrastructure with Terraform

Infraestrutura completa na AWS para uma aplicação full-stack (Next.js + Express.js + PostgreSQL), provisionada via Terraform com módulos, remote state e deploy manual via Docker + ECR.

## Arquitetura

```
Usuário
  │
  ▼ HTTPS
CloudFront (mpdesafio4.ezopscloud.co)
  ├── /* ──────────────► S3 (frontend estático Next.js)
  └── /api/* ──────────► ALB (HTTP:80)
                           └── ECS Fargate (backend Express.js :3001)
                                 └── RDS PostgreSQL (subnet privada)
```

## Stack

| Camada | Tecnologia |
|--------|------------|
| Frontend | Next.js 16 (export estático) |
| Backend | Express.js + Node.js |
| Banco de dados | PostgreSQL 16 (RDS) |
| Infraestrutura | Terraform |
| Container registry | Amazon ECR |
| Orquestração | ECS Fargate |
| CDN | CloudFront |
| Storage estático | S3 |
| Load balancer | ALB (Application Load Balancer) |
| DNS | Route53 |
| Certificado SSL | ACM (us-east-1 para CloudFront, us-east-2 para ALB) |
| Rede | VPC customizada com subnets públicas e privadas |

## Módulos Terraform

```
.
├── backend.tf              # Remote state (S3)
├── main.tf                 # Chamada dos módulos
├── outputs.tf
├── provider.tf             # aws us-east-2 + alias us-east-1
├── variables.tf
├── env/dev/terraform.tfvars  # NÃO commitado (contém senhas)
└── modules/
    ├── vpc/          # VPC, subnets, IGW, NAT Gateway, route tables
    ├── ecr/          # Repositórios ECR (frontend e backend)
    ├── ecs/          # Cluster, task definitions, services, ALB, security groups
    ├── rds/          # RDS instance, subnet group, security group
    ├── route53/      # Hosted zone
    ├── acm/          # Certificado SSL para o ALB (us-east-2)
    └── cloudfront/   # Distribuição CloudFront, certificado ACM (us-east-1), S3 bucket policy
```

## Rede

- **VPC:** `10.0.0.0/16`
- **Subnets públicas:** `publica-desafio4-1a`, `publica-desafio4-1b` — ALB
- **Subnets privadas:** `privada-desafio4-1a`, `privada-desafio4-1b` — ECS e RDS
- **NAT Gateway:** permite que ECS (subnet privada) acesse a internet para pull de imagens
- **Internet Gateway:** acesso público para o ALB

## Roteamento CloudFront → ALB

O CloudFront se comunica com o ALB via HTTP (porta 80), pois o certificado do ALB não cobre o DNS `.elb.amazonaws.com` — a segurança HTTPS é garantida entre o usuário e o CloudFront. O ALB responde somente a requisições no path `/api` e `/api/*`, com `fixed-response 404` como default.

## Variáveis de ambiente

### Frontend

A variável `NEXT_PUBLIC_API_URL` é embutida no build estático do Next.js e **não pode** ser injetada em runtime. Por isso é definida no `.env.production`:

```env
NEXT_PUBLIC_API_URL=https://mpdesafio4.ezopscloud.co
```

> `.env.production` pode ser commitado pois contém apenas uma URL pública.

### Backend

Variáveis sensíveis são injetadas via ECS task definition (Terraform), nunca commitadas:

```
DB_HOST, DB_USER, DB_PASS, DB_NAME, PORT
```

## Deploy

### Pré-requisitos

- Terraform >= 1.5
- AWS CLI configurado
- Docker

### Provisionamento da infraestrutura

```bash
terraform init
terraform plan -var-file="env/dev/terraform.tfvars"
terraform apply -var-file="env/dev/terraform.tfvars"
```

### Build e push das imagens

```bash
# Autenticar no ECR
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin 618889059366.dkr.ecr.us-east-2.amazonaws.com

# Backend
docker build -t backend ./backend
docker tag backend:latest 618889059366.dkr.ecr.us-east-2.amazonaws.com/backend:latest
docker push 618889059366.dkr.ecr.us-east-2.amazonaws.com/backend:latest

# Frontend (build estático)
cd frontend
npm run build
aws s3 sync ./out s3://mateus-pereira-lambda-artifacts/frontend --delete --region us-east-2
```

### Invalidar cache do CloudFront após atualizar o frontend

```bash
aws cloudfront create-invalidation \
  --distribution-id $(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items[?contains(@, 'mpdesafio4')]].Id" \
    --output text) \
  --paths "/*"
```

### Forçar redeploy do ECS backend

```bash
aws ecs update-service \
  --cluster desafio4-cluster \
  --service desafio4-backend-service \
  --force-new-deployment \
  --region us-east-2
```

## Desenvolvimento local

O projeto inclui um `docker-compose.yaml` com nginx, frontend, backend e PostgreSQL local.

```bash
docker-compose up --build
```

Acesse em `http://localhost`.

O nginx roteia `/api/*` para o backend e `/*` para o frontend, espelhando o comportamento do CloudFront + ALB em produção.

### Variáveis locais

Crie um `.env` na raiz do projeto (não commitado):

```env
DB_HOST=db
DB_USER=mateus
DB_PASS=mypassword
DB_NAME=mydb
POSTGRES_USER=mateus
POSTGRES_PASSWORD=mypassword
POSTGRES_DB=mydb
```

E um `.env.local` dentro de `frontend/`:

```env
NEXT_PUBLIC_API_URL=http://localhost
```

## Decisões técnicas

**Por que CloudFront em vez de ALB direto para o frontend?**
S3 + CloudFront é mais barato e escalável para assets estáticos do que manter um container ECS rodando 24/7 para servir HTML/JS/CSS.

**Por que dois certificados ACM?**
O CloudFront obrigatoriamente requer certificados na região `us-east-1`. O ALB usa um certificado em `us-east-2` (mesma região dos recursos).

**Por que `http-only` entre CloudFront e ALB?**
O certificado do ALB é emitido para `mpdesafio4.ezopscloud.co`, mas o CloudFront conecta pelo DNS do ALB (`*.elb.amazonaws.com`). Isso causa erro de SNI se usar HTTPS. A segurança é mantida pois o tráfego CloudFront → ALB ocorre dentro da rede da AWS.

**Por que remote state no S3?**
Permite que múltiplos membros da equipe compartilhem o estado do Terraform sem conflitos, com lock via arquivo no próprio S3.

## URLs

| Ambiente | URL |
|----------|-----|
| Produção | https://mpdesafio4.ezopscloud.co |
| Health check | https://mpdesafio4.ezopscloud.co/api/health |

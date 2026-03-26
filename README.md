# Desafio Semana 4/6 — Observabilidade & Resiliência na AWS

Infraestrutura completa na AWS para uma aplicação full-stack (Next.js + Express.js + PostgreSQL), provisionada via Terraform com módulos, remote state e deploy manual via Docker + ECR. Inclui stack de observabilidade com Amazon Managed Prometheus (AMP), Grafana e alerting nativo via Grafana Alerting + Slack.

## Arquitetura

```
Usuário
  │
  ▼ HTTPS
CloudFront (<SEU_SUBDOMINIO>)
  ├── /*  ────────────► S3 (frontend estático Next.js)
  ├── /api/* ──────────► ALB (HTTP:80)
  │                        └── ECS Fargate (backend Express.js :3001)
  │                              └── RDS PostgreSQL (subnet privada)
  └── /grafana* ───────► ALB (HTTP:80)
                           └── ECS Fargate (Grafana :3000)

Comunicação interna (VPC):
  Prometheus (AMP) ──scrape──► backend:3001  (via Cloud Map)
  Grafana          ──query───► AMP  (via SigV4)
  Grafana Alerting ──notify──► Slack
```

## Stack

| Camada | Tecnologia |
|--------|------------|
| Frontend | Next.js (export estático) |
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
| Métricas | Amazon Managed Prometheus (AMP) |
| Dashboards | Grafana |
| Alertas | Grafana Alerting + Slack |
| Service discovery | AWS Cloud Map |

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
    ├── ecr/          # Repositórios ECR (frontend, backend, grafana)
    ├── ecs/          # Cluster, task definitions, services, ALB, security groups, Cloud Map
    ├── rds/          # RDS instance, subnet group, security group
    ├── route53/      # Hosted zone
    ├── acm/          # Certificado SSL para o ALB (us-east-2)
    └── cloudfront/   # Distribuição CloudFront, certificado ACM (us-east-1), S3 bucket policy
```

## Rede

- **VPC:** `10.0.0.0/16`
- **Subnets públicas:** `publica-desafio4-1a`, `publica-desafio4-1b` — ALB, Grafana
- **Subnets privadas:** `privada-desafio4-1a`, `privada-desafio4-1b` — Backend e RDS
- **NAT Gateway:** permite que ECS (subnet privada) acesse a internet para pull de imagens
- **Internet Gateway:** acesso público para o ALB

## Roteamento CloudFront → ALB

O CloudFront se comunica com o ALB via HTTP (porta 80), pois o certificado do ALB não cobre o DNS `.elb.amazonaws.com` — a segurança HTTPS é garantida entre o usuário e o CloudFront. O ALB responde somente a requisições nos paths configurados, com `fixed-response 404` como default.

| Path | Destino |
|------|---------|
| `/api/*` | ECS backend :3001 |
| `/metrics` | ECS backend :3001 (scrape do Prometheus) |
| `/grafana*` | ECS Grafana :3000 |

## Observabilidade

### Arquitetura interna

O Grafana é o único componente de observabilidade exposto publicamente. O AMP é um serviço gerenciado da AWS acessado via API com autenticação SigV4 — sem containers extras para Prometheus ou Alertmanager.

```
Internet → CloudFront → ALB → Grafana (autenticado)
                                  ↓ SigV4
                              Amazon AMP
                                  ↑ remote_write
                              backend:3001
                              (via Cloud Map)

Grafana Alerting → Slack
```

### Serviços

| Serviço | Tipo | Acesso |
|---------|------|--------|
| Grafana | ECS Fargate (imagem customizada) | Público via `/grafana` (login obrigatório) |
| Amazon AMP | Serviço gerenciado AWS | Interno via SigV4 |

### Imagem customizada do Grafana

O Grafana usa uma imagem customizada baseada em `grafana/grafana:latest` com AWS CLI instalado via `apk`. No startup, o entrypoint baixa todos os arquivos de configuração do S3 antes de iniciar o serviço:

```dockerfile
FROM grafana/grafana:latest

USER root

RUN apk add --no-cache aws-cli

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

```bash
# entrypoint.sh
#!/bin/sh
set -e

echo "Baixando configs do S3..."
aws s3 cp s3://${CONFIGS_BUCKET}/observability/grafana/datasources.yml \
    /etc/grafana/provisioning/datasources/datasources.yml
aws s3 cp s3://${CONFIGS_BUCKET}/observability/grafana/dashboards.yml \
    /etc/grafana/provisioning/dashboards/dashboards.yml
aws s3 sync s3://${CONFIGS_BUCKET}/observability/grafana/dashboards/ \
    /var/lib/grafana/dashboards/
aws s3 cp s3://${CONFIGS_BUCKET}/observability/grafana/alerting/rules.yml \
    /etc/grafana/provisioning/alerting/rules.yml
aws s3 cp s3://${CONFIGS_BUCKET}/observability/grafana/alerting/notification-policies.yml \
    /etc/grafana/provisioning/alerting/notification-policies.yml
aws s3 cp s3://${CONFIGS_BUCKET}/observability/grafana/alerting/contact-points.yml \
    /etc/grafana/provisioning/alerting/contact-points.yml

echo "Iniciando Grafana..."
exec /run.sh "$@"
```

### Estrutura de arquivos no S3

```
<CONFIGS_BUCKET>/observability/grafana/
├── datasources.yml
├── dashboards.yml
├── dashboards/
│   └── dashboard.json
└── alerting/
    ├── rules.yml
    ├── notification-policies.yml
    └── contact-points.yml
```

### Alertas configurados

| Alerta | Condição | Severidade |
|--------|----------|------------|
| `ServiceDown` | Backend sem resposta por 15s | critical |
| `HighErrorRate` | Taxa de erros 5xx > 5% por 1 minuto | warning |
| `HighMemoryUsage` | RAM > 150MB por 2 minutos | warning |

As notificações são enviadas para o Slack (`#treinamento-devops-pub`) com estado de firing e resolved. O `repeat_interval` está configurado para 10 minutos para evitar spam.

### IAM Roles

No ECS existem duas roles distintas:

| Role | Usada por | Permissões |
|------|-----------|------------|
| `execution role` | ECS (gerencia a task) | ECR pull, CloudWatch Logs, Cloud Map register |
| `task role` (observability) | Container em runtime | S3 read (configs), AMP write/query (SigV4) |

## Variáveis de ambiente

### Frontend

A variável `NEXT_PUBLIC_API_URL` é embutida no build estático do Next.js e **não pode** ser injetada em runtime. Por isso é definida no `.env.production`:

```env
NEXT_PUBLIC_API_URL=https://<SEU_SUBDOMINIO>
```

> `.env.production` pode ser commitado pois contém apenas uma URL pública.

### Backend

Variáveis sensíveis são injetadas via ECS task definition (Terraform), nunca commitadas:

```
DB_HOST, DB_USER, DB_PASS, DB_NAME, PORT
```

### Grafana

```
GF_SECURITY_ADMIN_PASSWORD      # definida no terraform.tfvars (não commitado)
GF_SERVER_ROOT_URL              # https://<SEU_SUBDOMINIO>/grafana
GF_SERVER_SERVE_FROM_SUB_PATH   # true
GF_AUTH_SIGV4_AUTH_ENABLED      # true (necessário para autenticar com AMP)
CONFIGS_BUCKET                  # nome do bucket S3 com os arquivos de config
AWS_DEFAULT_REGION              # us-east-2
AWS_REGION                      # us-east-2
AWS_SDK_LOAD_CONFIG             # true
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
aws ecr get-login-password --region <AWS_REGION> | \
  docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com

# Backend
docker build -t backend ./backend
docker tag backend:latest <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-backend:latest
docker push <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-backend:latest

# Frontend (build estático)
cd frontend
npm run build
aws s3 sync ./out s3://<S3_BUCKET>/frontend --delete --region <AWS_REGION>

# Grafana (imagem customizada)
docker build --no-cache -t grafana-build observability/grafana/
docker tag grafana-build:latest <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-grafana:latest
docker push <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-grafana:latest
```

### Upload das configs para o S3

```bash
# Datasource e dashboards
aws s3 cp observability/grafana/datasources.yml \
    s3://<CONFIGS_BUCKET>/observability/grafana/datasources.yml
aws s3 cp observability/grafana/dashboards.yml \
    s3://<CONFIGS_BUCKET>/observability/grafana/dashboards.yml
aws s3 sync observability/grafana/dashboards/ \
    s3://<CONFIGS_BUCKET>/observability/grafana/dashboards/

# Alerting
aws s3 cp observability/grafana/alerting/rules.yml \
    s3://<CONFIGS_BUCKET>/observability/grafana/alerting/rules.yml
aws s3 cp observability/grafana/alerting/notification-policies.yml \
    s3://<CONFIGS_BUCKET>/observability/grafana/alerting/notification-policies.yml
aws s3 cp observability/grafana/alerting/contact-points.yml \
    s3://<CONFIGS_BUCKET>/observability/grafana/alerting/contact-points.yml
```

### Invalidar cache do CloudFront após atualizar o frontend

```bash
aws cloudfront create-invalidation \
  --distribution-id $(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items[?contains(@, '<SEU_SUBDOMINIO>')]].Id" \
    --output text) \
  --paths "/*"
```

### Forçar redeploy dos serviços ECS

```bash
# Backend
aws ecs update-service --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-backend-service --force-new-deployment --region us-east-2

# Grafana
aws ecs update-service --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-grafana-service --force-new-deployment --region us-east-2
```

### Pausar e retomar serviços

```bash
# Pausar (ex: para manutenção ou parar alertas durante debug)
aws ecs update-service --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-grafana-service --desired-count 0 --region us-east-2

# Retomar
aws ecs update-service --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-grafana-service --desired-count 1 --region us-east-2
```

### Simular falha de serviço

```bash
# Derrubar o backend
aws ecs update-service --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-backend-service --desired-count 0 --region us-east-2

# Subir o backend
aws ecs update-service --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-backend-service --desired-count 1 --region us-east-2
```

## Desenvolvimento local

O projeto inclui um `docker-compose.yaml` com nginx, frontend, backend, PostgreSQL, Prometheus e Grafana local.

```bash
docker-compose up --build
```

Acesse em `http://localhost`.

O nginx roteia `/api/*` para o backend e `/*` para o frontend, espelhando o comportamento do CloudFront + ALB em produção.

### Variáveis locais

Crie um `.env` na raiz do projeto (não commitado):

```env
DB_HOST=db
DB_USER=<SEU_USUARIO>
DB_PASS=<SUA_SENHA>
DB_NAME=<SEU_BANCO>
POSTGRES_USER=<SEU_USUARIO>
POSTGRES_PASSWORD=<SUA_SENHA>
POSTGRES_DB=<SEU_BANCO>
```

E um `.env.local` dentro de `frontend/`:

```env
NEXT_PUBLIC_API_URL=http://localhost
```

## Decisões técnicas

**Por que Amazon Managed Prometheus (AMP) em vez de Prometheus self-hosted?**
O AMP elimina a necessidade de gerenciar containers de Prometheus e Alertmanager no ECS. O serviço é gerenciado pela AWS, com alta disponibilidade e retenção de dados persistente — sem perda de métricas a cada redeploy.

**Por que Grafana Alerting em vez de Alertmanager separado?**
Com AMP, o Alertmanager self-hosted perde o principal motivo de existir (receber alertas do Prometheus). O Grafana Alerting cobre o mesmo caso de uso com menos infraestrutura: sem container extra, sem imagem customizada, sem deploy adicional.

**Por que CloudFront em vez de ALB direto para o frontend?**
S3 + CloudFront é mais barato e escalável para assets estáticos do que manter um container ECS rodando 24/7 para servir HTML/JS/CSS.

**Por que dois certificados ACM?**
O CloudFront obrigatoriamente requer certificados na região `us-east-1`. O ALB usa um certificado em `us-east-2` (mesma região dos recursos).

**Por que `http-only` entre CloudFront e ALB?**
O certificado do ALB é emitido para `<SEU_SUBDOMINIO>`, mas o CloudFront conecta pelo DNS do ALB (`*.elb.amazonaws.com`). Isso causa erro de SNI se usar HTTPS. A segurança é mantida pois o tráfego CloudFront → ALB ocorre dentro da rede da AWS.

**Por que remote state no S3?**
Permite que múltiplos membros da equipe compartilhem o estado do Terraform sem conflitos, com lock via arquivo no próprio S3.

**Por que as configs do Grafana ficam no S3?**
No ECS Fargate não é possível montar arquivos locais como no Docker Compose. O S3 é a solução padrão para armazenar configs que precisam ser acessadas pelas tasks no startup, permitindo atualizar datasources, dashboards e alerting sem rebuildar a imagem.

**Por que a imagem do Grafana é customizada?**
A imagem oficial não inclui AWS CLI. A customização instala o AWS CLI via `apk add aws-cli` (compatível com Alpine/musl) e adiciona o entrypoint que sincroniza as configs do S3 antes de iniciar o Grafana.

## URLs

| Ambiente | URL |
|----------|-----|
| Produção | https://<SEU_SUBDOMINIO> |
| Health check | https://<SEU_SUBDOMINIO>/api/health |
| Grafana | https://<SEU_SUBDOMINIO>/grafana |

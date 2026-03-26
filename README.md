# Desafio Semana 4 — AWS Infrastructure with Terraform

Infraestrutura completa na AWS para uma aplicação full-stack (Next.js + Express.js + PostgreSQL), provisionada via Terraform com módulos, remote state e deploy manual via Docker + ECR. Inclui stack completo de observabilidade com Prometheus, Grafana e Alertmanager.

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
  Prometheus ──scrape──► backend:3001  (via ALB /metrics)
  Prometheus ──alerts──► alertmanager.local:9093  (via Cloud Map)
  Grafana    ──query───► prometheus.local:9090  (via Cloud Map)
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
| Métricas | Prometheus |
| Dashboards | Grafana |
| Alertas | Alertmanager + Slack |
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
    ├── ecr/          # Repositórios ECR (frontend, backend, prometheus, grafana, alertmanager)
    ├── ecs/          # Cluster, task definitions, services, ALB, security groups, Cloud Map
    ├── rds/          # RDS instance, subnet group, security group
    ├── route53/      # Hosted zone
    ├── acm/          # Certificado SSL para o ALB (us-east-2)
    └── cloudfront/   # Distribuição CloudFront, certificado ACM (us-east-1), S3 bucket policy
```

## Rede

- **VPC:** `10.0.0.0/16`
- **Subnets públicas:** `publica-desafio4-1a`, `publica-desafio4-1b` — ALB, Grafana, Prometheus, Alertmanager
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

O stack de observabilidade roda inteiramente no ECS Fargate. Prometheus e Alertmanager **não são expostos publicamente** — apenas o Grafana é acessível via CloudFront, protegido por autenticação.

```
Internet → CloudFront → ALB → Grafana (autenticado)
                                  ↓ (interno)
                              Prometheus
                             ↙          ↘
                     backend:3001    Alertmanager
                     (via ALB)       (via Cloud Map)
                                         ↓
                                       Slack
```

### Serviços

| Serviço | Imagem | Acesso |
|---------|--------|--------|
| Grafana | `grafana/grafana:latest` | Público via `/grafana` (login obrigatório) |
| Prometheus | Customizada (Prometheus + AWS CLI) | Interno apenas |
| Alertmanager | Customizada (Alertmanager + AWS CLI) | Interno apenas |

### Imagens customizadas

Prometheus e Alertmanager usam imagens customizadas com AWS CLI instalado. No startup, um entrypoint baixa os arquivos de configuração do S3 antes de iniciar o serviço:

```bash
# entrypoint.sh (Prometheus)
aws s3 cp s3://${CONFIGS_BUCKET}/observability/prometheus.yml /etc/prometheus/prometheus.yml
aws s3 cp s3://${CONFIGS_BUCKET}/observability/alerts.yml /etc/prometheus/alerts.yml
exec /bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --web.enable-lifecycle \
  --storage.tsdb.path=/prometheus \
  --web.external-url=http://localhost/prometheus \
  --web.route-prefix=/prometheus
```

Os arquivos de configuração ficam armazenados no S3 (`<S3_BUCKET>/observability/`).

### Service Discovery (Cloud Map)

No ECS Fargate os IPs das tasks são dinâmicos e mudam a cada deploy. O AWS Cloud Map registra o IP atual de cada task em um DNS privado dentro da VPC (namespace `.local`):

| DNS | Serviço |
|-----|---------|
| `backend.local` | Backend Express |
| `prometheus.local` | Prometheus |
| `alertmanager.local` | Alertmanager |

### Alertas configurados

| Alerta | Condição | Severidade |
|--------|----------|------------|
| `ServiceDown` | Backend sem resposta por 15s | critical |
| `HighErrorRate` | Taxa de erros 5xx > 5% por 1 minuto | warning |
| `HighMemoryUsage` | RAM > 150MB por 2 minutos | warning |

As notificações são enviadas para o Slack com estado de firing e resolved.

### IAM Roles

No ECS existem duas roles distintas:

| Role | Usada por | Permissões |
|------|-----------|------------|
| `execution role` | ECS (gerencia a task) | ECR pull, CloudWatch logs, Cloud Map register |
| `task role` (observability) | Container em runtime | S3 read (configs) |

### Atualizar configurações do Prometheus ou Alertmanager

```bash
# Edita o arquivo localmente e faz upload para o S3
aws s3 cp observability/prometheus/prometheus.yml s3://<S3_BUCKET>/observability/prometheus.yml
aws s3 cp observability/alertmanager/alertmanager.yml s3://<S3_BUCKET>/observability/alertmanager.yml

# Força novo deploy para a task baixar as configs atualizadas
aws ecs update-service --cluster desafio4-cluster --service desafio4-prometheus-service --force-new-deployment --region us-east-2
aws ecs update-service --cluster desafio4-cluster --service desafio4-alertmanager-service --force-new-deployment --region us-east-2
```

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
GF_SECURITY_ADMIN_PASSWORD  # definida no terraform.tfvars (não commitado)
GF_SERVER_ROOT_URL          # https://<SEU_SUBDOMINIO>/grafana
GF_SERVER_SERVE_FROM_SUB_PATH # true
```

### Prometheus e Alertmanager

```
CONFIGS_BUCKET      # nome do bucket S3 com os arquivos de config
AWS_DEFAULT_REGION  # us-east-2
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
docker tag backend:latest <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/backend:latest
docker push <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/backend:latest

# Frontend (build estático)
cd frontend
npm run build
aws s3 sync ./out s3://<S3_BUCKET>/frontend --delete --region <AWS_REGION>

# Prometheus (imagem customizada)
docker build -t prometheus-build observability/prometheus/
docker tag prometheus-build <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-prometheus:latest
docker push <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-prometheus:latest

# Alertmanager (imagem customizada)
docker build -t alertmanager-build observability/alertmanager/
docker tag alertmanager-build <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-alertmanager:latest
docker push <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-alertmanager:latest

# Grafana (imagem pública, só tag e push)
docker pull grafana/grafana:latest
docker tag grafana/grafana:latest <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-grafana:latest
docker push <AWS_ACCOUNT_ID>.dkr.ecr.<AWS_REGION>.amazonaws.com/<PROJECT_NAME>-grafana:latest
```

### Upload das configs para o S3

```bash
aws s3 cp observability/prometheus/prometheus.yml s3://<S3_BUCKET>/observability/prometheus.yml
aws s3 cp observability/prometheus/alerts.yml s3://<S3_BUCKET>/observability/alerts.yml
aws s3 cp observability/alertmanager/alertmanager.yml s3://<S3_BUCKET>/observability/alertmanager.yml
```

### Invalidar cache do CloudFront após atualizar o frontend

```bash
aws cloudfront create-invalidation \
  --distribution-id $(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Items[?contains(@, 'mpdesafio4')]].Id" \
    --output text) \
  --paths "/*"
```

### Forçar redeploy dos serviços ECS

```bash
# Backend
aws ecs update-service --cluster desafio4-cluster --service desafio4-backend-service --force-new-deployment --region us-east-2

# Prometheus
aws ecs update-service --cluster desafio4-cluster --service desafio4-prometheus-service --force-new-deployment --region us-east-2

# Grafana
aws ecs update-service --cluster desafio4-cluster --service desafio4-grafana-service --force-new-deployment --region us-east-2

# Alertmanager
aws ecs update-service --cluster desafio4-cluster --service desafio4-alertmanager-service --force-new-deployment --region us-east-2
```

### Simular falha de serviço

```bash
# Derrubar o backend
aws ecs update-service --cluster desafio4-cluster --service desafio4-backend-service --desired-count 0 --region us-east-2

# Subir o backend
aws ecs update-service --cluster desafio4-cluster --service desafio4-backend-service --desired-count 1 --region us-east-2
```

## Desenvolvimento local

O projeto inclui um `docker-compose.yaml` com nginx, frontend, backend, PostgreSQL, Prometheus, Grafana e Alertmanager local.

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

**Por que CloudFront em vez de ALB direto para o frontend?**
S3 + CloudFront é mais barato e escalável para assets estáticos do que manter um container ECS rodando 24/7 para servir HTML/JS/CSS.

**Por que dois certificados ACM?**
O CloudFront obrigatoriamente requer certificados na região `us-east-1`. O ALB usa um certificado em `us-east-2` (mesma região dos recursos).

**Por que `http-only` entre CloudFront e ALB?**
O certificado do ALB é emitido para `<SEU_SUBDOMINIO>`, mas o CloudFront conecta pelo DNS do ALB (`*.elb.amazonaws.com`). Isso causa erro de SNI se usar HTTPS. A segurança é mantida pois o tráfego CloudFront → ALB ocorre dentro da rede da AWS.

**Por que remote state no S3?**
Permite que múltiplos membros da equipe compartilhem o estado do Terraform sem conflitos, com lock via arquivo no próprio S3.

**Por que Prometheus e Alertmanager não são expostos publicamente?**
Expor ferramentas de observabilidade publicamente representa um risco de segurança — qualquer pessoa poderia ver métricas internas, regras de alerta e status da infraestrutura. Apenas o Grafana é exposto, com autenticação obrigatória, e serve como ponto único de acesso para visualização.

**Por que as configs do Prometheus e Alertmanager ficam no S3?**
No ECS Fargate não é possível montar arquivos locais como no Docker Compose. O S3 é a solução padrão para armazenar configs que precisam ser acessadas pelas tasks no startup, permitindo atualizar as configurações sem precisar rebuildar as imagens.

**Por que o Prometheus faz scrape via ALB e não via Cloud Map?**
O `dns_sd_configs` remove o target completamente quando não há instâncias registradas no Cloud Map (ex: quando o backend está com `desired-count 0`). Sem target, a métrica `up` some e o alerta `ServiceDown` nunca dispara. Com `static_configs` apontando para o ALB, o target sempre existe e o Prometheus registra `up=0` corretamente quando o backend cai.

## URLs

| Ambiente | URL |
|----------|-----|
| Produção | https://<SEU_SUBDOMINIO> |
| Health check | https://<SEU_SUBDOMINIO>/api/health |
| Grafana | https://<SEU_SUBDOMINIO>/grafana |


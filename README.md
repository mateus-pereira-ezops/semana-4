# Desafio 4 — Infraestrutura como Código com Terraform na AWS

Infraestrutura completa para rodar uma aplicação Next.js + Express.js com banco de dados PostgreSQL na AWS, provisionada inteiramente via Terraform.

---

## Arquitetura

```
Internet
    │
    ▼
Application Load Balancer (ALB)
    │
    ├── /* ──────────────── ECS Fargate (Frontend - Next.js :3000)
    │
    └── /api/* ──────────── ECS Fargate (Backend - Express.js :3001)
                                │
                                ▼
                        RDS PostgreSQL (subnets privadas)
```

### Componentes

- **VPC** — rede isolada com subnets públicas e privadas em 2 Availability Zones
- **ECR** — repositórios Docker para as imagens do frontend e backend
- **ECS Fargate** — execução dos containers sem gerenciamento de servidores
- **ALB** — balanceador de carga que roteia tráfego entre frontend e backend
- **RDS PostgreSQL** — banco de dados nas subnets privadas (sem acesso público)
- **S3** — armazenamento do remote state do Terraform

---

## Estrutura do Projeto

```
.
├── backend.tf              # Configuração do remote state (S3)
├── main.tf                 # Chamada dos módulos
├── outputs.tf              # Outputs da infra (ALB DNS, ECR URLs, etc.)
├── provider.tf             # Configuração do provider AWS
├── variables.tf            # Variáveis raiz
├── env/
│   └── dev/
│       └── terraform.tfvars  # Valores das variáveis (não commitar senhas)
└── modules/
    ├── vpc/                # VPC, subnets, IGW, route tables
    ├── ecr/                # Repositórios ECR
    ├── ecs/                # Cluster, Task Definition, Service, ALB
    └── rds/                # Instância RDS, subnet group, security group
```

---

## Pré-requisitos

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configurado com credenciais válidas
- [Docker](https://www.docker.com/) para build e push das imagens
- Bucket S3 criado para o remote state

---

## Configuração

### 1. Variáveis

Crie o arquivo `env/dev/terraform.tfvars` com os valores do ambiente:

```hcl
project_name = "desafio4"
db_password  = "SuaSenhaSegura"
```

> **Nunca commite este arquivo.** Ele já está no `.gitignore`.

### 2. Variáveis de ambiente esperadas pelo Backend

| Variável   | Descrição                        |
|------------|----------------------------------|
| `DB_HOST`  | Endpoint do RDS (sem porta)      |
| `DB_USER`  | Usuário do banco                 |
| `DB_PASS`  | Senha do banco                   |
| `DB_NAME`  | Nome do banco                    |
| `DB_PORT`  | Porta do banco (padrão: `5432`)  |
| `PORT`     | Porta do servidor (padrão: `3001`) |

---

## Deploy

### 1. Inicializar o Terraform

```bash
terraform init
```

### 2. Validar a configuração

```bash
terraform validate
```

### 3. Visualizar o plano

```bash
terraform plan -var-file=env/dev/terraform.tfvars
```

### 4. Aplicar a infraestrutura

```bash
terraform apply -var-file=env/dev/terraform.tfvars
```

### 5. Obter as URLs geradas

```bash
terraform output
```

Exemplo de output:
```
alb_dns         = "desafio4-alb-xxxxxxxxxx.us-east-2.elb.amazonaws.com"
ecr_frontend_url = "xxxxxxxxxxxx.dkr.ecr.us-east-2.amazonaws.com/frontend"
ecr_backend_url  = "xxxxxxxxxxxx.dkr.ecr.us-east-2.amazonaws.com/backend"
```

---

## Build e Push das Imagens Docker

Após o `terraform apply`, envie as imagens para o ECR.

### 1. Autenticar o Docker no ECR

```bash
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin <ID_CONTA>.dkr.ecr.us-east-2.amazonaws.com
```

### 2. Build e push do frontend

```bash
docker build -t frontend ./caminho/do/nextjs
docker tag frontend:latest <ECR_FRONTEND_URL>:latest
docker push <ECR_FRONTEND_URL>:latest
```

### 3. Build e push do backend

```bash
docker build -t backend ./caminho/do/express
docker tag backend:latest <ECR_BACKEND_URL>:latest
docker push <ECR_BACKEND_URL>:latest
```

### 4. Forçar novo deployment no ECS

```bash
aws ecs update-service \
  --cluster desafio4-cluster \
  --service desafio4-service \
  --force-new-deployment \
  --region us-east-2
```

### 5. Verificar se a task está rodando

```bash
aws ecs describe-services \
  --cluster desafio4-cluster \
  --services desafio4-service \
  --region us-east-2 \
  --query "services[0].{running:runningCount,pending:pendingCount,desired:desiredCount}"
```

---

## Testando a Aplicação

Com `running: 1`, acesse:

| Endpoint | Descrição |
|----------|-----------|
| `http://<ALB_DNS>/` | Frontend (Next.js) |
| `http://<ALB_DNS>/api/health` | Health check do backend |
| `http://<ALB_DNS>/api/db-time` | Consulta ao banco de dados |

---

## Destruir a Infraestrutura

```bash
terraform destroy -var-file=env/dev/terraform.tfvars
```

> O ECR está configurado com `force_delete = true` e o RDS com `deletion_protection = false`, então o destroy funciona sem intervenção manual.

---

## Remote State

O state é armazenado remotamente no S3 com locking habilitado:

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket       = "mateus-pereira-lambda-artifacts"
    key          = "dev/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

Em caso de lock travado (ex: após falha), desbloqueie com:

```bash
terraform force-unlock <LOCK_ID>
```

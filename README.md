# Desafio 4 — Infraestrutura como Código com Terraform na AWS

Infraestrutura completa para rodar uma aplicação Next.js + Express.js com banco de dados PostgreSQL na AWS, provisionada inteiramente via Terraform.

---

## Arquitetura

```
Internet
    │
    ▼ (HTTP :80 → redirect 301)
    ▼ (HTTPS :443)
Application Load Balancer (ALB) — subnets públicas
    │
    ├── /* ──────────────── ECS Fargate (Frontend - Next.js :3000)
    │                             │ subnets privadas
    └── /api, /api/* ────── ECS Fargate (Backend - Express.js :3001)
                                  │ subnets privadas
                                  ▼
                          RDS PostgreSQL (subnets privadas)

subnets privadas → NAT Gateway → Internet (saída apenas)
```

### Componentes

- **VPC** — rede isolada com subnets públicas e privadas em 2 Availability Zones
- **NAT Gateway** — permite que recursos nas subnets privadas acessem a internet (saída apenas)
- **ECR** — repositórios Docker para as imagens do frontend e backend
- **ECS Fargate** — dois services independentes (frontend e backend) nas subnets privadas
- **ALB** — balanceador de carga nas subnets públicas com HTTPS e redirect HTTP → HTTPS
- **ACM** — certificado SSL gratuito validado via DNS pelo Route53
- **Route53** — subdomínio `mpdesafio4.ezopscloud.co` apontando para o ALB
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
    ├── vpc/                # VPC, subnets, IGW, NAT Gateway, route tables
    ├── ecr/                # Repositórios ECR
    ├── ecs/                # Cluster, Task Definitions, Services, ALB
    ├── rds/                # Instância RDS, subnet group, security group
    ├── route53/            # Registro DNS apontando para o ALB
    └── acm/                # Certificado SSL e validação via DNS
```

---

## Pré-requisitos

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configurado com credenciais válidas
- [Docker](https://www.docker.com/) para build e push das imagens
- Bucket S3 criado para o remote state
- Domínio registrado no Route53

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

| Variável   | Descrição                          |
|------------|------------------------------------|
| `DB_HOST`  | Endpoint do RDS (sem porta)        |
| `DB_USER`  | Usuário do banco                   |
| `DB_PASS`  | Senha do banco                     |
| `DB_NAME`  | Nome do banco                      |
| `DB_PORT`  | Porta do banco (padrão: `5432`)    |
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
alb_dns          = "desafio4-alb-xxxxxxxxxx.us-east-2.elb.amazonaws.com"
app_url          = "https://mpdesafio4.ezopscloud.co"
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
# Frontend
aws ecs update-service \
  --cluster desafio4-cluster \
  --service desafio4-frontend-service \
  --force-new-deployment \
  --region us-east-2

# Backend
aws ecs update-service \
  --cluster desafio4-cluster \
  --service desafio4-backend-service \
  --force-new-deployment \
  --region us-east-2
```

### 5. Verificar se os services estão rodando

```bash
aws ecs describe-services \
  --cluster desafio4-cluster \
  --services desafio4-frontend-service desafio4-backend-service \
  --region us-east-2 \
  --query "services[*].{name:serviceName,running:runningCount,desired:desiredCount}"
```

---

## Testando a Aplicação

### Endpoints gerais

| Endpoint | Descrição |
|----------|-----------|
| `https://mpdesafio4.ezopscloud.co/` | Frontend (Next.js) |
| `https://mpdesafio4.ezopscloud.co/api/health` | Health check do backend |
| `https://mpdesafio4.ezopscloud.co/api/db-time` | Consulta ao banco de dados |

> HTTP redireciona automaticamente para HTTPS via redirect 301.

### CRUD de Tarefas

A tabela `tasks` é criada automaticamente na primeira execução do backend.

| Método | Endpoint | Descrição |
|--------|----------|-----------|
| `POST` | `/api/tasks` | Criar tarefa |
| `GET` | `/api/tasks` | Listar todas |
| `GET` | `/api/tasks/:id` | Buscar uma |
| `PUT` | `/api/tasks/:id` | Atualizar |
| `DELETE` | `/api/tasks/:id` | Deletar |

**Exemplos:**

```bash
# Criar
curl -X POST https://mpdesafio4.ezopscloud.co/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"title": "Minha tarefa"}'

# Listar
curl https://mpdesafio4.ezopscloud.co/api/tasks

# Buscar
curl https://mpdesafio4.ezopscloud.co/api/tasks/1

# Atualizar
curl -X PUT https://mpdesafio4.ezopscloud.co/api/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{"done": true}'

# Deletar
curl -X DELETE https://mpdesafio4.ezopscloud.co/api/tasks/1
```

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

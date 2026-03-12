module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
  aws_region   = var.aws_region
}

module "rds" {
  source             = "./modules/rds"
  project_name       = var.project_name
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = "10.0.0.0/16"
  private_subnet_ids = module.vpc.private_subnet_ids
  db_pass            = var.db_pass
}

module "ecr" {
  source           = "./modules/ecr"
  project_name     = var.project_name
  repository_names = ["frontend", "backend"]
}

module "ecs" {
  source = "./modules/ecs"

  project_name       = var.project_name
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  frontend_image = "${module.ecr.repository_urls["frontend"]}:latest"
  backend_image  = "${module.ecr.repository_urls["backend"]}:latest"

  db_endpoint     = module.rds.db_endpoint
  db_host         = module.rds.db_host
  db_name         = module.rds.db_name
  db_pass         = var.db_pass
  certificate_arn = module.acm.certificate_arn
  subdomain       = "mpdesafio4.ezopscloud.co"
}

module "route53" {
  source = "./modules/route53"

  alb_dns     = module.ecs.alb_dns
  alb_zone_id = module.ecs.alb_zone_id
}

module "acm" {
  source         = "./modules/acm"
  project_name   = var.project_name
  hosted_zone_id = module.route53.zone_id
}

module "cloudfront" {
  source = "./modules/cloudfront"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name   = var.project_name
  subdomain      = "mpdesafio4.ezopscloud.co"
  hosted_zone_id = module.route53.zone_id
  alb_dns        = module.ecs.alb_dns
}

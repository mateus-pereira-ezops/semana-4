output "ecr_frontend_url" {
  value = module.ecr.repository_urls["frontend"]
}

output "ecr_backend_url" {
  value = module.ecr.repository_urls["backend"]
}

output "alb_dns" {
  value = module.ecs.alb_dns
}

output "db_endpoint" {
  value     = module.rds.db_endpoint
  sensitive = true
}

output "db_host" {
  value     = module.rds.db_host
  sensitive = true
}

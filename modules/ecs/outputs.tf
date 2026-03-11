output "alb_dns" {
  value = aws_lb.main.dns_name
}

output "alb_zone_id" {
  value = aws_lb.main.zone_id
}

output "db_host" {
  value     = var.db_host
  sensitive = true
}


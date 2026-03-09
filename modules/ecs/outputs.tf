output "alb_dns" {
  value = aws_lb.main.dns_name
}

output "db_host" {
  value     = var.db_host
  sensitive = true
}

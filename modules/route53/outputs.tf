output "app_url" {
  value = "http://${var.subdomain}"
}

output "zone_id" {
  value = data.aws_route53_zone.main.zone_id
}
